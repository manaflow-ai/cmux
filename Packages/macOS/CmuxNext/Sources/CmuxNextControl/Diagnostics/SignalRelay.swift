import CmuxNextCompat
import Darwin
import Dispatch
import os

/// The last relayed signal and its sender (`si_pid`; 0 when the kernel sent it), as one record:
/// the signal in the high 32 bits, the pid in the low 32. One lock-free atomic store, so the
/// action is async-signal-safe and a reader never pairs one signal with another's sender.
private let lastRelayedSignal = Atomic<Int64>(0)

/// Records who sent the signal and does nothing else: the signal only has to be caught, not
/// ignored, so that its default action does not end the process. `SignalRelay`'s dispatch
/// source sees every delivery either way (kqueue `EVFILT_SIGNAL`).
private let relayedSignalHandler: @convention(c) (Int32, UnsafeMutablePointer<__siginfo>?, UnsafeMutableRawPointer?) -> Void = {
    signal, info, _ in
    lastRelayedSignal.store(SignalRelay.record(signal: signal, sender: info?.pointee.si_pid ?? 0), ordering: .relaxed)
}

/// Delivers process signals on the main queue through a `DispatchSource`
/// per signal; nothing runs in signal-handler context (the app's `QuitSignal`).
///
/// The signals are caught by a handler that only records the sender, instead of `SIG_IGN`: a caught
/// signal returns to its default action in every child the app execs, while
/// an ignored one stays ignored there (posix_spawn without
/// `POSIX_SPAWN_SETSIGDEF`, forkpty), so a shell started by the app would
/// ignore Ctrl-C and `kill`.
@MainActor
public final class SignalRelay {
    public let signals: [Int32]
    private var sources: [any DispatchSourceSignal] = []

    public init(signals: [Int32], handler: @escaping @MainActor (Int32) -> Void) {
        self.signals = signals
        for signal in signals {
            let source = DispatchSource.makeSignalSource(signal: signal, queue: .main)
            source.setEventHandler {
                // Who sent it, before anything acts on it: a launch smoke was ended at launch by a SIGTERM
                // that nothing traced (quit origin=signal, 2026-11-25). `log show --predicate 'processID == N'` names N.
                Self.logger.notice("signal \(signal, privacy: .public) from \(Self.senderDescription(of: signal), privacy: .public)")
                MainActor.assumeIsolated { handler(signal) } // main-proof: dispatch source on queue: .main
            }
            source.resume()
            sources.append(source)
        }
        catchSignals()
    }

    nonisolated private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.quit")

    /// `signal` and `sender` as one atomic record (see `lastRelayedSignal`).
    nonisolated static func record(signal: Int32, sender: pid_t) -> Int64 {
        Int64(truncatingIfNeeded: signal) << 32 | Int64(truncatingIfNeeded: UInt32(bitPattern: sender))
    }

    /// The pid that last sent `signal`, when it is the last signal the relay caught and a process
    /// (not the kernel) sent it. Dispatch coalesces deliveries, so this is the latest sender.
    public nonisolated static func lastSender(of signal: Int32) -> Int32? {
        let record = lastRelayedSignal.load(ordering: .relaxed)
        guard Int32(truncatingIfNeeded: record >> 32) == signal else { return nil }
        let pid = Int32(truncatingIfNeeded: record)
        return pid > 0 ? pid : nil
    }

    /// `signal`'s sender for a log line: "sender pid N", or "sender unknown".
    public nonisolated static func senderDescription(of signal: Int32) -> String {
        lastSender(of: signal).map { "sender pid \($0)" } ?? "sender unknown"
    }

    /// Installs the sender-recording handler for each signal. Call again after anything
    /// that resets signal actions (Chromium's start).
    public func catchSignals() {
        // The atomics are made here, never first inside the action (a global's one-time init is not async-signal-safe).
        _ = lastRelayedSignal.load(ordering: .relaxed)
        for signal in signals {
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = relayedSignalHandler
            action.sa_flags = SA_RESTART | SA_SIGINFO
            sigemptyset(&action.sa_mask)
            sigaction(signal, &action, nil)
        }
    }

    /// Stops relaying and gives each signal its default action back.
    public func cancel() {
        for source in sources { source.cancel() }
        sources = []
        for signal in signals { _ = Darwin.signal(signal, SIG_DFL) }
    }
}
