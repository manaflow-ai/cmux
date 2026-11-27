import Foundation

/// How often the phone tries again by itself, and when it stops (Leo 2026-11-24: "I feel like
/// there are often these like dead hang loops ... endless freezes, these soft locks if not hard
/// locks"). Each automatic retry here used to run forever; now each has a last try, after which
/// the failure stays on screen with the person's Retry.
public enum RetryBounds {
    /// A team that didn't load (register, then list its Macs): 5 s, 10 s, 20 s, 40 s, 60 s, then
    /// the Workspaces list's Retry (about 2 min of tries). Nil: stop trying by itself.
    public static func teamStartDelay(afterFailures failures: Int) -> Duration? {
        let backoff = [5, 10, 20, 40, 60]
        guard failures >= 1, failures <= backoff.count else { return nil }
        return .seconds(backoff[failures - 1])
    }

    /// A chats channel that didn't bind on a link that stays up: 1 s, 2 s, 4 s, 8 s, 15 s, then
    /// the Feed's Retry. `attempt` counts from 0. Nil: stop trying by itself.
    public static func chatsRebindDelay(attempt: Int) -> Duration? {
        let backoff = [1, 2, 4, 8, 15]
        guard attempt >= 0, attempt < backoff.count else { return nil }
        return .seconds(backoff[attempt])
    }

    /// Pairing asks the Mac again by itself at most this many times on one link (about 2.5 min;
    /// a rate limit, 3 times a minute apart). After that the refusal stays with Retry; a new link
    /// (foreground, network change, Retry) starts the count over.
    public static let pairingAttempts = 8
    public static let rateLimitedPairingAttempts = 3
}
