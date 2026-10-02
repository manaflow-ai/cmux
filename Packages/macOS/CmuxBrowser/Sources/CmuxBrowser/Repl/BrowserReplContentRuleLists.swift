public import Foundation
public import WebKit

/// The WebKit content rule list one REPL session compiles from its domain
/// policy (`session.configure({ contentRules })`), kept in a rule list store
/// under an identifier derived from the session id.
@MainActor
public final class BrowserReplContentRuleLists {
    /// The store identifier of this session's list.
    public let identifier: String
    private let store: WKContentRuleListStore

    public init(sessionID: String, store: WKContentRuleListStore) {
        let safe = sessionID.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }
            .joined()
        identifier = "cmux.browser-repl.\(safe)"
        self.store = store
    }

    /// Compiles `rules` (a JSON array of content-blocker rules) as the
    /// session's list.
    /// - Returns: The compiled list, or `nil` when `rules` is `nil` or empty.
    /// - Throws: ``BrowserReplDriverError`` `invalid` when the rules do not
    ///   compile.
    public func update(rules: Any?) async throws -> WKContentRuleList? {
        guard let rules = rules as? [Any], !rules.isEmpty else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let encoded = String(data: data, encoding: .utf8) else {
            throw BrowserReplDriverError(code: "invalid", message: "contentRules: expected a JSON array of content-blocker rules")
        }
        let identifier = identifier
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
}
