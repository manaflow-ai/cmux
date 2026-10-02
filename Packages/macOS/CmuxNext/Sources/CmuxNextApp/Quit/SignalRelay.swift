import Darwin
import Dispatch

/// Does nothing: the signal only has to be caught, not ignored, so that its
/// default action does not end the process. `SignalRelay`'s dispatch source
/// sees every delivery either way (kqueue `EVFILT_SIGNAL`).
private let relayedSignalHandler: @convention(c) (Int32) -> Void = { _ in }

/// Delivers process signals on the main queue through a `DispatchSource`
/// per signal; nothing runs in signal-handler context.
///
/// The signals are caught by a no-op handler instead of `SIG_IGN`: a caught
/// signal returns to its default action in every child the app execs, while
/// an ignored one stays ignored there (posix_spawn without
/// `POSIX_SPAWN_SETSIGDEF`, forkpty), so a shell started by the app would
/// ignore Ctrl-C and `kill`.
@MainActor
final class SignalRelay {
    let signals: [Int32]
    private var sources: [any DispatchSourceSignal] = []

    init(signals: [Int32], handler: @escaping @MainActor (Int32) -> Void) {
        self.signals = signals
        for signal in signals {
            let source = DispatchSource.makeSignalSource(signal: signal, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { handler(signal) }
            }
            source.resume()
            sources.append(source)
        }
        catchSignals()
    }

    /// Installs the no-op handler for each signal. Call again after anything
    /// that resets signal actions (Chromium's start).
    func catchSignals() {
        for signal in signals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = relayedSignalHandler
            action.sa_flags = SA_RESTART
            sigemptyset(&action.sa_mask)
            sigaction(signal, &action, nil)
        }
    }

    /// Stops relaying and gives each signal its default action back.
    func cancel() {
        for source in sources { source.cancel() }
        sources = []
        for signal in signals { _ = Darwin.signal(signal, SIG_DFL) }
    }
}
