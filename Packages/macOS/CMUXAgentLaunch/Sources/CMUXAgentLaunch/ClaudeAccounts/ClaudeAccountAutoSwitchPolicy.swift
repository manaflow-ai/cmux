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
public enum ClaudeAccountAutoSwitchPolicy {
    public static func decide(
        failureDetail: String?,
        current: ClaudeAccount,
        registry: ClaudeAccountRegistry,
        exhaustedKeys: Set<String>,
        isTrusted: (ClaudeAccount) -> Bool,
        homeDirectory: String
    ) -> ClaudeAccountAutoSwitchDecision {
        guard let failureDetail, failureDetail.hasPrefix("usage_limit") else {
            return .notUsageLimit
        }
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
