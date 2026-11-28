/// The existing pairing retry policy, shared by iOS and Linux reliability tests.
struct LinkPairingRetry {
    static func retryDelay(after code: String, attempt: Int) -> Duration? {
        switch code {
        // The person refused this phone on the Mac.
        case "denied": return nil
        // This host proved another identity than the one pinned, or answered for another Mac, or
        // the exchange itself was malformed: asking again on the same link cannot change that, and
        // the warning stays up. A new link (foreground, network change, Retry) pairs from the start.
        case "mac_identity_changed", "bad_mac_proof", "wrong_mac", "bad_request", "unpaired": return nil
        // The Mac asks about one phone a few times per 10 minutes; asking sooner is refused again.
        case "rate_limited": return attempt < RetryBounds.rateLimitedPairingAttempts ? .seconds(60) : nil
        default:
            // Bounded: after the last the refusal stays up with Retry (it was every 30 s forever).
            guard attempt < RetryBounds.pairingAttempts else { return nil }
            let backoff = [1, 2, 4, 8, 15]
            return .seconds(attempt < backoff.count ? backoff[max(attempt, 0)] : 30)
        }
    }
}
