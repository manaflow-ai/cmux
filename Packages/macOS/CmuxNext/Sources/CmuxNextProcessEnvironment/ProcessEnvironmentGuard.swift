import os
import Synchronization

/// The one gate for this process's environment writes (setenv, unsetenv).
///
/// libghostty keeps a fixed copy of `environ` from `ghostty_init`, so a write
/// after it left libghostty reading a freed entry (SIGSEGV, cx-9dh7). The
/// app therefore writes the environment only in `main`, before any thread
/// starts, and then calls ``freeze()``; `GhosttyRuntime` freezes again just
/// before `ghostty_init`. Every call site in
/// scripts/cmux-next/env-write-allowlist.json wraps its write in
/// ``write(_:_:)``, so a later reorder fails loudly instead of crashing
/// libghostty at random: a write after the freeze is skipped, logged once as
/// a fault, and stops a debug build (`assertionFailure`). Lock-free: two
/// atomics and a counter.
public final class ProcessEnvironmentGuard: Sendable {
    /// The guard of the real process environment.
    public static let process = ProcessEnvironmentGuard()

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "environment")

    private let frozen = Atomic<Bool>(false)
    private let reported = Atomic<Bool>(false)
    private let checkedWrites = Atomic<Int>(0)
    private let performsWrites: Bool
    private let onViolation: @Sendable (String) -> Void

    /// - Parameters:
    ///   - performsWrites: false runs no write body, so a test can drive the
    ///     real launch order without changing its own environment.
    ///   - onViolation: called on every write after ``freeze()``, after the
    ///     one-time fault log. The default stops debug builds and does
    ///     nothing in release builds.
    public init(performsWrites: Bool = true,
                onViolation: @escaping @Sendable (String) -> Void = { message in assertionFailure(message) }) {
        self.performsWrites = performsWrites
        self.onViolation = onViolation
    }

    /// True after ``freeze()``: no environment write may follow.
    public var isFrozen: Bool { frozen.load(ordering: .acquiring) }

    /// The write sites that ran (or, without `performsWrites`, would have
    /// run) before the freeze.
    public var writesBeforeFreeze: Int { checkedWrites.load(ordering: .acquiring) }

    /// Ends the window for environment writes. Idempotent.
    public func freeze() {
        frozen.store(true, ordering: .releasing)
    }

    /// Runs `body`, which may call setenv or unsetenv, unless the
    /// environment is frozen. After the freeze, `body` does not run: the
    /// first violation is logged as a fault and every violation reaches
    /// `onViolation`.
    public func write(_ site: StaticString, _ body: () -> Void) {
        guard !isFrozen else {
            let message = "environment write after the freeze at \(site): libghostty holds a copy of environ"
            if !reported.exchange(true, ordering: .acquiringAndReleasing) {
                Self.logger.fault("\(message, privacy: .public)")
            }
            onViolation(message)
            return
        }
        checkedWrites.add(1, ordering: .acquiringAndReleasing)
        if performsWrites { body() }
    }
}
