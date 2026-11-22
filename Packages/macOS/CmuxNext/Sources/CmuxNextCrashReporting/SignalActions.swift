public import Darwin

/// A saved set of signal actions, put back with ``restore()``.
///
/// The crash reporter needs two: the app's own `SIGPIPE` and `SIGTERM`
/// actions, which Sentry's start would replace with crash handlers (a
/// write to a closed pipe or a quit request would become a crash report),
/// and Sentry's fatal-signal handlers, which Chromium resets at its start
/// and the app puts back after it.
public nonisolated struct SignalActions: Sendable {
    public let signals: [Int32]
    private let actions: [sigaction]

    /// Reads the current action of each signal.
    public init(capturing signals: [Int32]) {
        self.signals = signals
        actions = signals.map { signal in
            var current = sigaction()
            sigaction(signal, nil, &current)
            return current
        }
    }

    /// Installs the saved actions again.
    public func restore() {
        for (signal, saved) in zip(signals, actions) {
            var action = saved
            sigaction(signal, &action, nil)
        }
    }

    /// Whether the saved action of `signal` is a handler (not the default
    /// action or ignore).
    public func hasHandler(for signal: Int32) -> Bool {
        guard let index = signals.firstIndex(of: signal) else { return false }
        // SIG_DFL is the handler value 0 and SIG_IGN is 1 (<sys/signal.h>).
        return unsafeBitCast(actions[index].__sigaction_u, to: Int.self) > 1
    }
}
