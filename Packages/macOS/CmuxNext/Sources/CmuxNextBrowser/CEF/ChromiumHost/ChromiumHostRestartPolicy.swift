#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import Foundation

/// Whether a Chromium Host that ended starts again: Chrome's GPU process crash
/// budget (`GpuProcessHost::RecordProcessCrash`, content/browser/gpu/gpu_process_host.cc).
///
/// - Each crash adds one to a recent-crash count; each ``forgiveAfter`` (5 min,
///   `kForgiveGpuCrashMinutes`) since the last crash takes one off. At
///   ``crashLimit`` (3, `GetFallbackCrashLimit()`) the host stays ended until the
///   person reloads, so a page that crashes its browser process at once never loops.
/// - An end of cmux's own (quit, logout, an update) spends nothing, as Chrome's
///   `IsSessionEnding()` does.
/// - A host that died before it said hello (`ready`, sent once Chromium's
///   context is initialized: CONTEXT_INITIALIZED) is not an ordinary crash, as
///   Chrome treats a GPU process that failed to initialize (`did_fail_initialize_`):
///   a new one would die the same way, so it goes to ``Decision/cannotStart(_:)``
///   at once, with no retry.
///
/// The clock is injected; the policy keeps only durations since it was made.
nonisolated struct ChromiumHostRestartPolicy: Sendable {
    /// `kForgiveGpuCrashMinutes`.
    static let standardForgiveAfter: Duration = .seconds(5 * 60)
    /// `GetFallbackCrashLimit()`.
    static let standardCrashLimit = 3

    /// What the owner of the host does after its end.
    nonisolated enum Decision: Equatable, Sendable {
        /// A crash within the budget: start a new host with the saved pages.
        case restart
        /// An end of cmux's own: nothing is counted, and the owner starts the next host when it needs one.
        case notCounted
        /// The budget is spent (`crashes` recent crashes): no host starts until the person reloads.
        case ended(crashes: Int)
        /// The host died before it said hello: no host starts until the person reloads.
        case cannotStart(ChromiumHostCannotStart)
    }

    let forgiveAfter: Duration
    let crashLimit: Int
    /// Crashes not forgiven yet (Chrome's `recent_crash_count_`).
    private(set) var recentCrashes = 0
    /// When the last counted crash came, as time since the policy was made (Chrome's `last_crash_time_`).
    private var lastCrash: Duration?
    private let elapsed: @Sendable () -> Duration

    init() {
        self.init(clock: ContinuousClock())
    }

    init<C: Clock>(clock: C, forgiveAfter: Duration = ChromiumHostRestartPolicy.standardForgiveAfter,
                   crashLimit: Int = ChromiumHostRestartPolicy.standardCrashLimit) where C.Duration == Duration {
        let start = clock.now
        elapsed = { start.duration(to: clock.now) }
        self.forgiveAfter = forgiveAfter
        self.crashLimit = crashLimit
    }

    /// Whether this end is a host that could not start (``Decision/cannotStart(_:)``). Only for such an end
    /// does the owner check the host's code signature (a slow read) and give the result to
    /// ``hostEnded(_:saidHello:cause:signature:)``.
    static func cannotStart(_ exit: ChromiumHostExit, saidHello: Bool, cause: ChromiumHostEndCause) -> Bool {
        cause == .crash && (!saidHello || exit.startFailure != nil)
    }

    /// Counts the end of a host and says what happens next.
    ///
    /// - Parameters:
    ///   - exit: How the host ended.
    ///   - saidHello: The host sent `ready` (its Chromium context is initialized) before it ended.
    ///   - cause: Why it ended, as its owner knows it.
    ///   - signature: The check of the host's code signature, part of a cannot-start decision.
    mutating func hostEnded(_ exit: ChromiumHostExit, saidHello: Bool, cause: ChromiumHostEndCause,
                            signature: ChromiumHostSignatureCheck = .notChecked) -> Decision {
        guard cause == .crash else { return .notCounted }
        if Self.cannotStart(exit, saidHello: saidHello, cause: cause) {
            return .cannotStart(ChromiumHostCannotStart(exit: exit, signature: signature))
        }
        let now = elapsed()
        recentCrashes += 1
        if let lastCrash {
            let forgiven = Int((now - lastCrash) / forgiveAfter)
            recentCrashes = max(0, recentCrashes - forgiven)
        }
        lastCrash = now
        return recentCrashes >= crashLimit ? .ended(crashes: recentCrashes) : .restart
    }
}

/// Why a Chromium Host ended, as the process that owns it knows it.
nonisolated enum ChromiumHostEndCause: Sendable, Equatable {
    /// It ended by itself (a crash, a CHECK, an exit nobody asked for) or something outside cmux killed it.
    case crash
    /// cmux ended it on purpose, or cmux quits.
    case quit
    /// The person logs out, or the Mac shuts down or restarts.
    case logout
    /// An app update (Sparkle) or a Chromium runtime update ends it.
    case update
}

/// A Chromium Host that died before it said hello: the exit, and the check of
/// the host's code signature (macOS kills a process whose signature is
/// broken before its first line runs, so that check is the first question).
nonisolated struct ChromiumHostCannotStart: Error, Equatable, Sendable, CustomStringConvertible {
    var exit: ChromiumHostExit
    var signature: ChromiumHostSignatureCheck = .notChecked

    /// The exit with its meaning (``ChromiumHostExit/startFailures``), then the signature check.
    var description: String {
        let ended = exit.startFailure ?? "could not start (\(exit)): it ended before Chromium started"
        guard let signature = signature.text else { return ended }
        return "\(ended); \(signature)"
    }
}
#endif
