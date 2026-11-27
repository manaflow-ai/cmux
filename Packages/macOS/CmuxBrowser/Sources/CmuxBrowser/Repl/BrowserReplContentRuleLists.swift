public import Foundation
public import WebKit

/// The WebKit content rule list one REPL session compiles from its domain
/// policy (`session.configure({ contentRules })`), kept in a rule list store
/// under an identifier derived from the session id. New rules replace the
/// stored list; clearing the rules (also done when the session ends)
/// removes it from the store, which is persistent.
@MainActor
public final class BrowserReplContentRuleLists {
    /// The store identifier of this session's list.
    public let identifier: String
    private let store: WKContentRuleListStore
    /// Whether the store may hold this session's list.
    private var stored = false

    public init(sessionID: String, store: WKContentRuleListStore) {
        let safe = sessionID.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }
            .joined()
        identifier = "cmux.browser-repl.\(safe)"
        self.store = store
    }

    /// Compiles `rules` (a JSON array of content-blocker rules) as the
    /// session's list.
    /// - Returns: The compiled list, or `nil` when `rules` is `nil` or empty,
    ///   which removes the stored list.
    /// - Throws: ``BrowserReplDriverError`` `invalid` when the rules do not
    ///   compile.
    public func update(rules: Any?) async throws -> WKContentRuleList? {
        guard let rules = rules as? [Any], !rules.isEmpty else {
            await removeStoredList()
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let encoded = String(data: data, encoding: .utf8) else {
            throw BrowserReplDriverError(code: "invalid", message: "contentRules: expected a JSON array of content-blocker rules")
        }
        let identifier = identifier
        stored = true
        return try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: encoded) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: BrowserReplDriverError(
                        code: "invalid",
                        message: "contentRules: \(error?.localizedDescription ?? "could not compile")"
                    ))
                }
            }
        }
    }

    /// The rules a tab a session created carries while WebKit compiles the
    /// rules of the session's latest policy or directories, and after it
    /// refused them: every load is blocked. WebKit compiles a list
    /// asynchronously while the tab's page keeps running, so without them
    /// the page could load, under the previous rules, what the new ones
    /// forbid (``BrowserReplPolicyBoard/ruleState(for:)``).
    public static let failClosedRules: [[String: Any]] = [
        ["trigger": ["url-filter": ".*"], "action": ["type": "block"]],
    ]

    /// The identifier of the fail-closed list in a store.
    public static let failClosedIdentifier = "cmux.browser-repl.fail-closed"

    /// ``failClosedRules`` compiled in `store`.
    /// - Throws: ``BrowserReplDriverError`` `invalid` when WebKit refuses them.
    public static func failClosedList(in store: WKContentRuleListStore) async throws -> WKContentRuleList {
        guard let data = try? JSONSerialization.data(withJSONObject: failClosedRules),
              let encoded = String(data: data, encoding: .utf8) else {
            throw BrowserReplDriverError(code: "invalid", message: "contentRules: the fail-closed rules do not encode")
        }
        return try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: failClosedIdentifier, encodedContentRuleList: encoded) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: BrowserReplDriverError(
                        code: "invalid",
                        message: "contentRules: \(error?.localizedDescription ?? "could not compile")"
                    ))
                }
            }
        }
    }

    private func removeStoredList() async {
        guard stored else { return }
        stored = false
        let identifier = identifier
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // A list that never compiled is not there; that error is fine.
            store.removeContentRuleList(forIdentifier: identifier) { _ in continuation.resume() }
        }
    }
}
