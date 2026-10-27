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
            // SAFETY: with a nil new action sigaction changes nothing and writes the current one into `current`, a
            // local live for the call.
            unsafe sigaction(signal, nil, &current)
            return current
        }
    }

    /// Installs the saved actions again.
    public func restore() {
        for (signal, saved) in zip(signals, actions) {
            var action = saved
            // SAFETY: the kernel copies `action`, a local live for the call, an action sigaction itself returned for
            // this signal; no old action is asked for.
            unsafe sigaction(signal, &action, nil)
        }
    }
}
