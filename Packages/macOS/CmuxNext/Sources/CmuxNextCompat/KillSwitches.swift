/// Per-PR kill switches (leo-workspace briefs/2026-10-20-gui-push/partial-rollback.md, section 2):
/// the `pr-<N>` switches the signed flags document turns off on this Mac. A risky change keeps its
/// old path and asks ``killSwitch(_:)`` where the two split:
///
///     if killSwitch("pr-23456") { oldPath() } else { newPath() }
///
/// Nothing is off until ``KillSwitchReader`` applies a verified document,
/// and a missing or unverifiable one turns nothing off, so every change ships by default. The set
/// changes only between reads: call sites ask when they create a window, tab or pane, never during a
/// gesture. Each switch is declared, with its PR, owner and expiry, in
/// `release-notes/next/kill-switches.json` (`scripts/cmux-next/check-kill-switches.py`).
public final class KillSwitches: Sendable {
    /// The app's switches (the updater writes them; ``killSwitch(_:)`` reads them).
    // singleton-allow: the process-wide killSwitch API must share one verified set across call sites.
    public static let shared = KillSwitches()

    private let state = Mutex<Set<String>>([])

    public init() {}

    /// Whether the signed document turned off the switch `key` (`pr-<N>`).
    public func isOff(_ key: String) -> Bool {
        state.withLock { $0.contains(key) }
    }

    /// Every switch turned off now.
    public var off: Set<String> {
        state.withLock { $0 }
    }

    /// Replaces the turned-off switches with a newly verified document's.
    public func replace(off keys: Set<String>) {
        state.withLock { $0 = keys }
    }
}

/// Whether PR `key`'s change is turned off (`"pr-<N>"`, a literal declared in
/// `release-notes/next/kill-switches.json`): true runs the old path.
public func killSwitch(_ key: StaticString) -> Bool {
    KillSwitches.shared.isOff(key.description)
}
