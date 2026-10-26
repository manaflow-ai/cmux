import CmuxNextCompat
public import CmuxNextWakeups
import Darwin

/// A control socket bound and listening at ``path`` that no server accepts on yet
/// (``ControlSocketServer/bindListener(path:protectStateDirectory:)``, p08-startup-019).
///
/// One owner of the descriptor at a time: a server takes it once (``ControlSocketServer/start(adopting:)``);
/// a listener nobody took is closed and its socket file removed (only while the file is still this
/// one) by ``discard()`` or when it is released.
public final class ControlSocketListener: Sendable {
    /// Where the socket file is.
    public let path: String
    /// The socket file's identity when it was bound: ``discard()`` removes only that file.
    let identity: (dev: dev_t, ino: ino_t)?
    /// The listening descriptor, -1 once taken or discarded.
    private let descriptor: Atomic<Int32>

    init(path: String, descriptor: Int32, identity: (dev: dev_t, ino: ino_t)?) {
        self.path = path
        self.identity = identity
        self.descriptor = Atomic(descriptor)
    }

    deinit {
        discard()
    }

    /// The descriptor, for the one server that adopts it; nil once taken or discarded.
    func take() -> Int32? {
        let taken = descriptor.exchange(-1, ordering: .acquiringAndReleasing)
        return taken >= 0 ? taken : nil
    }

    /// Closes the listener and removes its socket file while that file is still this listener's:
    /// for a launch whose resolved access mode is `off`, or an app that quits before it serves.
    /// Clients waiting in the backlog see the connection reset. Nothing once a server took it.
    public func discard() {
        guard let descriptor = take() else { return }
        close(descriptor)
        ControlSocketServer.unlinkIfOwn(path, identity)
    }
}

/// The control socket's bind, begun in the app's `main()` on a ``BackgroundWork`` lane and handed to
/// the main thread when it is done (p08-startup-019). The control service adopts its listener after
/// its methods are registered, so the main thread never runs the owner check or the bind.
///
/// ```swift
/// // main(), after the launch order exists:
/// let socket = ControlSocketBind.begin(launch: environment.launch, environment: ProcessInfo.processInfo.environment,
///                                      work: work, mainWork: order.mainWork)
/// // after the methods are registered (ControlLaunch's last post):
/// service.serve(after: socket) { result in log(result) }
/// ```
@MainActor
public final class ControlSocketBind {
    /// The bound listener, or why there is none (`disabled` when the environment turns the socket
    /// off, `addressInUse` when another live instance owns the path).
    public typealias Outcome = Result<ControlSocketListener, ControlSocketServer.StartError>

    /// The outcome, once the lane finished the bind.
    public private(set) var outcome: Outcome?
    private var waiters: [@MainActor (Outcome) -> Void] = []
    /// ``discard()`` was called: a listener the lane hands over later is closed before any waiter sees it.
    private var isDiscarded = false

    /// A bind whose outcome ``finish(_:)`` gives (tests; the app uses ``begin(launch:environment:work:mainWork:)``).
    public init() {}

    /// Starts the bind of `launch`'s socket on `work`'s system lane at `userBlocking` (a person or an
    /// agent may be waiting on the CLI); the outcome comes back to main as an automation task.
    ///
    /// `CMUX_NEXT_SOCKET_MODE=off` binds nothing (``ControlService/resolveAccessMode(explicit:environment:configured:)``
    /// gives off for it whatever cmux.json says). The other modes all give the file mode 0600, so the
    /// bind does not need cmux.json; the service reads the configured mode after the settings load and
    /// discards the listener when it is off, before any connection is accepted.
    public static func begin(launch: LaunchIdentity, environment: [String: String], work: BackgroundWork,
                             mainWork: MainWorkScheduler) -> ControlSocketBind {
        let bind = ControlSocketBind()
        let path = launch.socketPath
        let protect = ControlService.protectsStateDirectory(launch)
        let off = environment["CMUX_NEXT_SOCKET_MODE"].flatMap(ControlService.parseAccessMode) == .off
        work.run(.userBlocking, mayBlock: .system) { () -> Outcome in
            if off { return .failure(.disabled) }
            do throws(ControlSocketServer.StartError) {
                return .success(try ControlSocketServer.bindListener(path: path, protectStateDirectory: protect))
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
