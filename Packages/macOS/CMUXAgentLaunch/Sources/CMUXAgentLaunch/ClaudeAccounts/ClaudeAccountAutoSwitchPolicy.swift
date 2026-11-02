import Foundation

/// What to do when a Claude session stops with a failure.
public enum ClaudeAccountAutoSwitchDecision: Equatable, Sendable {
    /// The failure is not a usage limit, so nothing switches.
    case notUsageLimit
    /// Every other account is exhausted or missing.
    case noAlternative
    /// Switch to this account. `sendContinue` is true only when the account is trusted for the
    /// session's directory, so the resumed session will not stop at a trust prompt.
    case switchTo(ClaudeAccount, sendContinue: Bool)
}

/// Pure policy choosing the next Claude account after a usage limit.
///
/// Built once for the home directory that resolves the default account and every account's
/// exhaustion key; ``decide(failureDetail:current:registry:exhaustedKeys:isTrusted:)`` reads only
/// what it is given.
public struct ClaudeAccountAutoSwitchPolicy: Equatable, Sendable {
    /// The failure-class token ``ClaudeStopFailure/journalDetail`` writes for a usage limit.
    public static let usageLimitToken = "usage_limit"

    /// Whether a journal failure detail reports a usage limit: the token alone, or the token, a
    /// colon and the message, as ``ClaudeStopFailure/journalDetail`` writes it. Another token
    /// that merely starts with the same letters is not one.
    public static func isUsageLimit(failureDetail: String?) -> Bool {
        guard let failureDetail else { return false }
        return failureDetail == usageLimitToken || failureDetail.hasPrefix(usageLimitToken + ":")
    }

    /// The home whose `.claude` is the default account; exhaustion keys are resolved against it.
    public let homeDirectory: String

    public init(homeDirectory: String) {
        self.homeDirectory = homeDirectory
    }

    /// The next account after `current` in `registry` order, wrapping, skipping `current` and
    /// `exhaustedKeys`; one that `isTrusted` comes first.
    ///
    /// - Parameters:
    ///   - failureDetail: The journal failure detail; anything but a usage limit switches nothing.
    ///   - current: The account the session ran under.
    ///   - registry: The accounts to rotate through.
    ///   - exhaustedKeys: Exhaustion keys of accounts to skip.
    ///   - isTrusted: Whether an account already trusts the session's folder.
    public func decide(
        failureDetail: String?,
        current: ClaudeAccount,
        registry: ClaudeAccountRegistry,
        exhaustedKeys: Set<String>,
        isTrusted: (ClaudeAccount) -> Bool
    ) -> ClaudeAccountAutoSwitchDecision {
        guard Self.isUsageLimit(failureDetail: failureDetail) else { return .notUsageLimit }
        let accounts = registry.accounts
        let currentKey = current.exhaustionKey(homeDirectory: homeDirectory)
        let keys = accounts.map { $0.exhaustionKey(homeDirectory: homeDirectory) }
        // An unregistered current account has no slot, so rotation starts from the first account.
        let ordered: [ClaudeAccount]
        if let index = keys.firstIndex(of: currentKey) {
            ordered = Array(accounts[(index + 1)...] + accounts[..<index])
        } else {
            ordered = accounts
        }
        let candidates = ordered.filter { account in
            let key = account.exhaustionKey(homeDirectory: homeDirectory)
            return key != currentKey && !exhaustedKeys.contains(key)
        }
        if let trusted = candidates.first(where: isTrusted) {
            return .switchTo(trusted, sendContinue: true)
        }
        if let first = candidates.first {
            return .switchTo(first, sendContinue: false)
        }
        return .noAlternative
    }
}
