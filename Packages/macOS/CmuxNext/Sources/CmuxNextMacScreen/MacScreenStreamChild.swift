import ApplicationServices
import CmuxNextCompat
import CmuxNextWakeups
import CmuxScreenKit
import CoreGraphics
import CoreFoundation
public import Foundation
import Security

/// The windows a child's capture leaves out (SECURITY: the app's windows only the person at this Mac
/// may see, `CaptureExcludedWindows`, read by the app and sent as `exclude_windows`), and who hears a
/// change.
nonisolated final class MacScreenStreamExclusions: Sendable {
    private let current = Mutex<Set<CGWindowID>>([])
    /// Called after every change (the capture backend's `exclusionsChanged`).
    private let changed = Mutex<(@Sendable () -> Void)?>(nil)

    var ids: Set<CGWindowID> { current.load() }

    func onChange(_ handler: @escaping @Sendable () -> Void) {
        changed.store(handler)
    }

    func set(_ ids: Set<CGWindowID>) {
        let previous = current.withLock { current in
            defer { current = ids }
            return current
        }
        guard previous != ids else { return }
        changed.load()?()
    }
}

/// What serves the child's one session: `ScreenStreamHost` in the app's build, a stand-in in tests.
nonisolated protocol MacScreenStreamServing: AnyObject, Sendable {
    func serve(_ signaling: any ScreenSignaling) async throws
    func disconnectViewer()
}

/// The child side of one session's signaling: the viewer's signals arrive as `signal` lines from the
/// app, this side's go out as `signal` lines, ICE servers are asked for with `ice_request`.
nonisolated final class MacScreenStreamChildSignaling: ScreenSignaling {
    struct NoICEServers: LocalizedError {
        var reason: String
        var errorDescription: String? { reason }
    }

    private let write: @Sendable (MacScreenStreamLine) -> Void
    private let stream: AsyncThrowingStream<ScreenSignal, any Error>
    private let continuation: AsyncThrowingStream<ScreenSignal, any Error>.Continuation
    private let pending = Mutex<(next: Int, waiting: [Int: CheckedContinuation<[ICEServerConfig], any Error>], ended: Bool)>((1, [:], false))
    private let closed = Mutex(false)
    let endsSessionOnClose: Bool

    init(endsSessionOnClose: Bool, write: @escaping @Sendable (MacScreenStreamLine) -> Void) {
        self.endsSessionOnClose = endsSessionOnClose
        self.write = write
        (stream, continuation) = AsyncThrowingStream.makeStream(of: ScreenSignal.self, throwing: (any Error).self,
                                                                bufferingPolicy: .bufferingOldest(512))
    }

    func messages() -> AsyncThrowingStream<ScreenSignal, any Error> { stream }

    func send(_ signal: ScreenSignal) async throws {
        write(MacScreenStreamLine(signal: .init(signal)))
    }

    func iceServers() async throws -> [ICEServerConfig] {
        try await withCheckedThrowingContinuation { waiter in
            let id = pending.withLock { state -> Int? in
                guard !state.ended else { return nil }
                let id = state.next
                state.next += 1
                state.waiting[id] = waiter
                return id
            }
            guard let id else { return waiter.resume(throwing: NoICEServers(reason: "the app ended the session")) }
            write(MacScreenStreamLine(iceRequest: id))
        }
    }

    func close() {
        let first = closed.withLock { closed in
            defer { closed = true }
            return !closed
        }
        if first { write(MacScreenStreamLine(close: true)) }
    }

    /// A signal from the viewer.
    func received(_ signal: ScreenSignal) {
        continuation.yield(signal)
    }

    /// The app's answer to one `ice_request`.
    func answered(_ ice: MacScreenStreamLine.ICE) {
        guard let waiter = pending.withLock({ $0.waiting.removeValue(forKey: ice.id) }) else { return }
        if let servers = ice.servers { waiter.resume(returning: servers) } else {
            waiter.resume(throwing: NoICEServers(reason: ice.error ?? "no ICE servers"))
        }
    }

    /// The app's signaling ended (or the app did): no more signals, and no ICE answer comes.
    func ended() {
        continuation.finish()
        let waiting = pending.withLock { state in
            state.ended = true
            defer { state.waiting.removeAll() }
            return Array(state.waiting.values)
        }
        for waiter in waiting { waiter.resume(throwing: NoICEServers(reason: "the app ended the session")) }
    }
}

/// The child's one session, driven by the lines the app writes: `setup` starts the host, `signal`,
/// `ice` and `exclude_windows` feed it, `stop` (or the app's end of input) disconnects it, and `done`
/// is written when its `serve` returns, then ``finished`` runs.
nonisolated final class MacScreenStreamChildSession: Sendable {
    typealias MakeHost = @Sendable (MacScreenStreamLine.Setup, MacScreenStreamExclusions,
                                    _ events: @escaping @Sendable (MacScreenStreamLine.Event, String?) -> Void) -> any MacScreenStreamServing

    private let write: @Sendable (MacScreenStreamLine) -> Void
    private let makeHost: MakeHost
    private let finished: @Sendable () -> Void
    let exclusions = MacScreenStreamExclusions()
    private let state = Mutex(State())

    private struct State {
        var signaling: MacScreenStreamChildSignaling?
        var host: (any MacScreenStreamServing)?
        var ended = false
    }

    init(write: @escaping @Sendable (MacScreenStreamLine) -> Void, makeHost: @escaping MakeHost,
         finished: @escaping @Sendable () -> Void) {
        self.write = write
        self.makeHost = makeHost
        self.finished = finished
    }

    func receive(_ line: MacScreenStreamLine) {
        // SECURITY: the list applies before the setup on the same line (the app sends it first).
        if let ids = line.excludeWindows { exclusions.set(Set(ids)) }
        if let setup = line.setup { start(setup) }
        let signaling = state.withLock { $0.signaling }
        if let signal = line.signal?.signal { signaling?.received(signal) }
        if let ice = line.ice { signaling?.answered(ice) }
        if line.stop == true { disconnect() }
    }

    /// The app closed this child's input (it stopped the session, or it ended).
    func inputEnded() {
        disconnect()
        // No setup came: nothing will write `done`.
        if state.withLock({ $0.signaling == nil }) { finished() }
    }

    private func disconnect() {
        let (signaling, host) = state.withLock { state in
            state.ended = true
            return (state.signaling, state.host)
        }
        host?.disconnectViewer()
        signaling?.ended()
    }

    private func start(_ setup: MacScreenStreamLine.Setup) {
        let write = write
        let signaling = MacScreenStreamChildSignaling(endsSessionOnClose: setup.endsSessionOnClose, write: write)
        let host = makeHost(setup, exclusions) { event, message in write(MacScreenStreamLine(event: event, message: message)) }
        let started = state.withLock { state -> Bool in
            guard state.signaling == nil, !state.ended else { return false }
            state.signaling = signaling
            state.host = host
            return true
        }
        guard started else { return }
        let finished = finished
        // task-owner: the child's one session; it ends with the host's serve, then the process exits
        Task.detached(priority: WorkPriority.userVisible.taskPriority) {
            var done = MacScreenStreamLine.Done()
            do { try await host.serve(signaling) } catch { done.error = String(describing: error) }
            write(MacScreenStreamLine(done: done))
            finished()
        }
    }
}

/// The app's executable run as the iPhone viewer's WebRTC screen host
/// (`<app executable> --screen-stream-host`): the Screen Sharing helper starts it as its own child
/// (`cmux-screen-sharing __webrtc-host`, which checks its code signature first), so its
/// ScreenCaptureKit capture and CGEvent input are the helper's responsibility and use the helper's
/// grants, never the app's: a grant made while cmux runs reaches the next session without a relaunch
/// (plans/cmux-next/screen-sharing-helper.md). It serves one session in ``MacScreenStreamLine`` JSON
/// lines on stdin and stdout, logs on stderr, and exits when the session ends or its input closes. It
/// starts no part of the app: no window, no daemon, no NSApplication.
nonisolated public struct MacScreenStreamChild: Sendable, Equatable {
    /// The mode argument (``MacScreenStreamProcess`` passes it).
    public static let flag = "--screen-stream-host"
    /// How long the child may take to end its session once its input closed.
    static let exitGrace: Double = 5

    /// The child mode when `arguments` (the process's, with its path first) ask for it.
    public init?(arguments: [String]) {
        guard arguments.count == 2, arguments[1] == Self.flag else { return nil }
    }

    /// Serves the session and exits; exits at once, serving nothing, when its parent is not this
    /// app's Screen Sharing helper.
    public func run() -> Never {
        // SECURITY: only the helper may start this mode. Any other launcher (`open --args`, a shell, a
        // terminal under the daemon) would make this process its own or the app's responsibility, so it
        // would capture and inject input under the app's grants for whoever holds its stdio.
        guard MacScreenStreamParent(pid: getppid()).isHelper(appBundleID: Bundle.main.bundleIdentifier,
                                                              ownTeam: MacScreenStreamParent.ownTeam()) else {
            try? FileHandle.standardError.write(contentsOf: Data("cmux screen stream host: refused: not started by this app's Screen Sharing helper\n".utf8))
            exit(64)
        }
        // A write to an app that ended fails with EPIPE instead of killing the child mid-cleanup.
        signal(SIGPIPE, SIG_IGN)
        let output = FileHandle.standardOutput
        // The lines to the app, in order; a write blocks only this queue.
        let writes = DispatchQueue(label: "com.cmuxterm.mac-screen.stream-host-stdout", qos: .userInitiated)
        let write: @Sendable (MacScreenStreamLine) -> Void = { line in
            guard let data = line.encoded else { return }
            writes.async { try? output.write(contentsOf: data) }
        }
        let errors = FileHandle.standardError
        let log: @Sendable (String) -> Void = { text in try? errors.write(contentsOf: Data((text + "\n").utf8)) }
        let session = MacScreenStreamChildSession(write: write, makeHost: { setup, exclusions, events in
            MacScreenStreamChildHost(setup: setup, exclusions: exclusions, events: events, log: log)
        }, finished: {
            // `done` and every line before it reach the app first.
            writes.blockingSync {}
            exit(0)
        })
        // What macOS checks for this process: the helper's grants (the fleet proof reads this line).
        write(MacScreenStreamLine(ready: .init(screenRecording: CGPreflightScreenCaptureAccess(), accessibility: AXIsProcessTrusted())))
        let reader = Thread {
            var splitter = MacScreenStreamLineSplitter()
            let input = FileHandle.standardInput
            // A dedicated thread, never the main one (it runs the run loop the capture needs); it ends at
            // the app's end of input.
            var data = input.blockingAvailableData()
            while !data.isEmpty {
                for line in splitter.push(data) { session.receive(line) }
                data = input.blockingAvailableData()
            }
            session.inputEnded()
            // The session ends with its input; one that does not within the grace ends here.
            // wakeup-allow: once, after the app's input closed; the process exits at it.
            // concurrency-allow: the child process's own stdout queue, never the app's main thread.
            writes.asyncAfter(deadline: .now() + Self.exitGrace) {
                log("cmux screen stream host: the session did not end within \(Self.exitGrace) s of its input closing")
                exit(0)
            }
        }
        reader.name = "screen-stream-host-input"
        reader.start()
        // The main run loop: display reconfiguration callbacks and the main actor run on it.
        CFRunLoopRun()
        exit(0)
    }
}

/// `ScreenStreamHost` over ScreenCaptureKit and CGEvent, as the app ran it in its own process.
nonisolated final class MacScreenStreamChildHost: MacScreenStreamServing {
    private let host: ScreenStreamHost

    init(setup: MacScreenStreamLine.Setup, exclusions: MacScreenStreamExclusions,
         events: @escaping @Sendable (MacScreenStreamLine.Event, String?) -> Void, log: @escaping @Sendable (String) -> Void) {
        // SECURITY: the capture leaves out the app's windows only the person at this Mac may see: the
        // list the app sends (`exclude_windows`) before the session and on every change.
        host = ScreenStreamHost(name: setup.name, viewOnly: setup.viewOnly, backend: {
            let backend = ScreenCaptureBackend(log: log)
            backend.excludedWindowIDs = { exclusions.ids }
            exclusions.onChange { [weak backend] in backend?.exclusionsChanged() }
            return backend
        }, log: log)
        host.onEvent = { event in
            switch event {
            case .viewerConnected: events(.viewerConnected, nil)
            case .viewerEnded: events(.viewerEnded, nil)
            case let .sourceFailed(message): events(.sourceFailed, message)
            case .waiting, .roomLost: break
            }
        }
    }

    func serve(_ signaling: any ScreenSignaling) async throws {
        try await host.serve(signaling)
    }

    func disconnectViewer() {
        host.disconnectViewer()
    }
}

/// The process that started a stream host child, read by pid (the child's parent is alive while it
/// runs; an orphan's parent is launchd, which never passes).
nonisolated struct MacScreenStreamParent {
    let pid: pid_t

    /// The helper's executable name (MacScreenHelper.executableName) and identifier suffix
    /// (bundle-screen-sharing-helper.sh: `<app id>.screen-sharing`).
    static let helperExecutable = "cmux-screen-sharing"
    static let helperSuffix = ".screen-sharing"

    /// This process's Team ID; nil for an ad hoc (local) build.
    static func ownTeam() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// A team-signed build: the parent is Apple-anchored, signed by this build's team, with the
    /// identifier `<app id>.screen-sharing`. An ad hoc build (no team, its grants a dev build's own):
    /// the parent runs the helper's executable.
    func isHelper(appBundleID: String?, ownTeam: String?) -> Bool {
        guard pid > 1 else { return false }
        guard let ownTeam else { return executableName == Self.helperExecutable }
        guard let appBundleID, let requirement = Self.requirement(team: ownTeam, identifier: appBundleID + Self.helperSuffix)
        else { return false }
        return satisfies(requirement)
    }

    /// The requirement text, or nil when the team or identifier holds a character with no place in one.
    static func requirement(team: String, identifier: String) -> String? {
        let plain = { (text: String) in
            !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
        }
        guard plain(team), plain(identifier) else { return nil }
        return "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    private var executableName: String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func satisfies(_ text: String) -> Bool {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            return false
        }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
