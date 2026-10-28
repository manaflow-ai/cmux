import CmuxNextCompat
public import CmuxNextWakeups
import Darwin

/// A control socket bound and listening at ``path`` that no server accepts on yet
/// (``ControlSocketServer/bindListener(path:protectStateDirectory:compatibilityLink:accessMode:)``),
/// with the path's owner lock and the compatibility link the bind made.
///
/// One owner of the descriptor and the lock at a time: a server takes both once
/// (``ControlSocketServer/start(adopting:)``); a listener nobody took is closed, its socket file and
/// link removed (only while they are still this one's) and its lock released by ``discard()`` or
/// when it is released.
public final class ControlSocketListener: Sendable {
    /// Where the socket file is.
    public let path: String
    /// The socket file's identity when it was bound: ``discard()`` removes only that file.
    let identity: (dev: dev_t, ino: ino_t)?
    /// The socket file's permissions: a server adopts the listener only for its own mode's.
    let mode: mode_t
    /// The symlink to ``path`` the bind made at the socket's old name, or nil.
    let compatibilityLink: String?
    /// The listening descriptor, -1 once taken or discarded.
    private let descriptor: Atomic<Int32>
    /// The owner lock (``ControlSocketServer/lockOwner(_:)``), -1 once taken or discarded, or when the
    /// lock file could not be used.
    private let lock: Atomic<Int32>

    init(path: String, descriptor: Int32, identity: (dev: dev_t, ino: ino_t)?, mode: mode_t, lock: Int32,
         compatibilityLink: String?) {
        self.path = path
        self.identity = identity
        self.mode = mode
        self.compatibilityLink = compatibilityLink
        self.descriptor = Atomic(descriptor)
        self.lock = Atomic(lock)
    }

    deinit {
        discard()
    }

    /// The descriptor and the owner lock, for the one server that adopts them; nil once taken or
    /// discarded.
    func take() -> (descriptor: Int32, lock: Int32)? {
        let taken = descriptor.exchange(-1, ordering: .acquiringAndReleasing)
        guard taken >= 0 else { return nil }
        return (taken, lock.exchange(-1, ordering: .acquiringAndReleasing))
    }

    /// Closes the listener, removes its socket file and link while they are still this listener's,
    /// then releases the owner lock: for a launch whose resolved access mode is `off`, or an app that
    /// quits before it serves. Clients waiting in the backlog see the connection reset. Nothing once
    /// a server took it.
    public func discard() {
        guard let taken = take() else { return }
        close(taken.descriptor)
        ControlSocketServer.unlinkIfOwn(path, identity)
        if let compatibilityLink { ControlSocketServer.unlinkLink(compatibilityLink, to: path) }
        ControlSocketServer.releaseOwner(taken.lock, of: path)
    }
}

/// The control socket's bind, begun on a ``BackgroundWork`` lane right after the launch's settings
/// read and handed to the main thread when it is done (feature
/// `controlSocketEarlyBind`). The control service adopts its listener after its methods are
/// registered, so the main thread never runs the owner check, the bind or the link.
///
/// ```swift
/// // applicationDidFinishLaunching, after the settings launch read:
/// let socket = ControlSocketBind.begin(launch: environment.launch, environment: ProcessInfo.processInfo.environment,
///                                      configured: settingsRead.snapshot.root.value(at: ["automation", "socketControlMode"])?.stringValue,
///                                      work: work, mainWork: order.mainWork)
/// // after the methods are registered (ControlLaunch's last post):
/// service.serve(after: socket) { result in log(result) }
/// ```
@MainActor
public final class ControlSocketBind {
    /// The bound listener, or why there is none (`disabled` when the resolved access mode is off,
    /// `addressInUse` when another live instance owns the path).
    public typealias Outcome = Result<ControlSocketListener, ControlSocketServer.StartError>

    /// The outcome, once the lane finished the bind.
    public private(set) var outcome: Outcome?
    private var waiters: [@MainActor (Outcome) -> Void] = []
    /// ``discard()`` was called: a listener the lane hands over later is closed before any waiter sees it.
    private var isDiscarded = false

    /// A bind whose outcome ``finish(_:)`` gives (tests; the app uses
    /// ``begin(launch:environment:configured:work:mainWork:)``).
    public init() {}

    /// Starts the bind of `launch`'s socket with the access mode the launch resolves: the environment
    /// (`CMUX_NEXT_SOCKET_MODE`), else `configured` (cmux.json's `automation.socketControlMode` with
    /// the managed layers, from the settings launch read), else the default, as
    /// ``ControlService/resolveAccessMode(explicit:environment:configured:)`` resolves it for the
    /// service. A mode of `off` (and the retired `password`) binds nothing: no socket file is made.
    ///
    /// - Parameters:
    ///   - launch: The socket path, its state folder rule and its compatibility link.
    ///   - environment: The process environment.
    ///   - configured: The configured mode string, or nil.
    ///   - work: The lanes; the bind runs on the system lane at `userBlocking` (a person or an agent
    ///     may be waiting on the CLI).
    ///   - mainWork: Where the outcome comes back, as an automation task.
    public static func begin(launch: LaunchIdentity, environment: [String: String], configured: String?,
                             work: BackgroundWork, mainWork: MainWorkScheduler) -> ControlSocketBind {
        begin(path: launch.socketPath, protectStateDirectory: ControlService.protectsStateDirectory(launch),
              compatibilityLink: launch.compatibilityLink,
              accessMode: ControlService.resolveAccessMode(explicit: nil, environment: environment, configured: configured),
              work: work, mainWork: mainWork)
    }

    /// ``begin(launch:environment:configured:work:mainWork:)`` with a resolved mode and an explicit path.
    static func begin(path: String, protectStateDirectory: Bool, compatibilityLink: String?, accessMode: ControlAccessMode,
                      work: BackgroundWork, mainWork: MainWorkScheduler) -> ControlSocketBind {
        let bind = ControlSocketBind()
        guard accessMode != .off else {
            bind.finish(.failure(.disabled))
            return bind
        }
        work.run(.userBlocking, mayBlock: .system) { () -> Outcome in
            do throws(ControlSocketServer.StartError) {
                return .success(try ControlSocketServer.bindListener(path: path, protectStateDirectory: protectStateDirectory,
                                                                     compatibilityLink: compatibilityLink, accessMode: accessMode))
            } catch {
                return .failure(error)
            }
        }.reply(on: mainWork, class: .automation, owner: "ControlSocket.bound") { [bind] outcome in
            bind.finish(outcome)
        }
        return bind
    }

    /// Calls `body` with the outcome: at once when the bind is done, else when it finishes.
    public func whenBound(_ body: @escaping @MainActor (Outcome) -> Void) {
        if let outcome { return body(outcome) }
        waiters.append(body)
    }

    /// Discards the listener nobody adopted (quit, or a resolved access mode of `off`), now or as soon
    /// as the bind finishes, before any waiter sees it: a later adopt throws `discarded`. Nothing once
    /// a server adopted it.
    public func discard() {
        isDiscarded = true
        if case .success(let listener)? = outcome { listener.discard() }
    }

    /// The bind finished.
    public func finish(_ outcome: Outcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        if isDiscarded, case .success(let listener) = outcome { listener.discard() }
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter(outcome) }
    }
}
