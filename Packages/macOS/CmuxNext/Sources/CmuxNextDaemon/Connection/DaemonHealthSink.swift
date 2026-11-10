import CmuxNextCompat

/// What the local daemon's launcher and connection tell app health (the shared health contract,
/// parts `sessionDaemon`, `acpmux` and `pageHost`): read-only facts, never a decision. The kill,
/// replace, timeout and reconnect rules stay their owners'. One instance per service, injected: the
/// launcher (``DaemonLauncher/health``) and the connection (``DaemonConnectionConfiguration/health``)
/// write to it, and the App binds its receiver once (``bind(_:)``). A sink made before the App's
/// services exist (the launch's first connect attempt) keeps its first signals until it is bound.
public final class DaemonHealthSink: Sendable {
    public enum Signal: Sendable, Equatable {
        /// The owner an ensure waits on reported its first restore progress: a start that counts
        /// toward a restart loop. A probe of an owner that is up but not answering never sends it.
        case started
        /// An owner answers (`server status` found it, or `server ensure` returned it).
        case ready(pid: Int32)
        /// `server ensure` failed or timed out: the owner it started did not become ready.
        case exited
        /// The owner `server ensure` waits on reported restore progress (a `--restore-progress` write).
        case restoring
        /// A request ended in `DaemonError.timedOut` (the first since the last answer).
        case requestTimedOut
        /// A request was answered after a timeout.
        case requestAnswered
        /// The daemon's page listener had to be asked for (its credential file was missing).
        case pageListenerMissing
        /// The daemon's page listener is up.
        case pageListenerReady
    }

    private struct State {
        var receiver: (@Sendable (Signal) -> Void)?
        /// Signals before the first ``bind(_:)`` (at most ``earlyLimit``).
        var early: [Signal] = []
        var timedOut = false
    }

    static let earlyLimit = 16
    private let state = Mutex(State())

    public init() {}

    /// Sends every signal to `receiver` from now on, on the thread that saw it; the signals that came
    /// before go first.
    public func bind(_ receiver: @escaping @Sendable (Signal) -> Void) {
        let early = state.withLock { state -> [Signal] in
            state.receiver = receiver
            defer { state.early = [] }
            return state.early
        }
        for signal in early { receiver(signal) }
    }

    /// Hands every signal on to `sink` (a launch's first attempt to the service that takes it over).
    public func forward(to sink: DaemonHealthSink) {
        bind { sink.note($0) }
    }

    public func note(_ signal: Signal) {
        let receiver = state.withLock { state -> (@Sendable (Signal) -> Void)? in
            if state.receiver == nil, state.early.count < Self.earlyLimit { state.early.append(signal) }
            return state.receiver
        }
        receiver?(signal)
    }

    /// One request's end: only a change (the first timeout, the first answer after it) is a signal.
    func noteRequest(timedOut: Bool) {
        let changed = state.withLock { state -> Bool in
            guard state.timedOut != timedOut else { return false }
            state.timedOut = timedOut
            return true
        }
        if changed { note(timedOut ? .requestTimedOut : .requestAnswered) }
    }
}

/// One ensure's progress for app health: its first progress write is the start (``DaemonHealthSink/Signal/started``),
/// then each write is ``DaemonHealthSink/Signal/restoring``.
final class EnsureProgressNote: Sendable {
    private let sink: DaemonHealthSink
    private let started = Mutex(false)

    init(_ sink: DaemonHealthSink) { self.sink = sink }

    func progressed() {
        let first = started.withLock { started in
            defer { started = true }
            return !started
        }
        if first { sink.note(.started) }
        sink.note(.restoring)
    }
}
