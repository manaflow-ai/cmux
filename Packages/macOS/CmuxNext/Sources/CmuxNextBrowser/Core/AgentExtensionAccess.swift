public import Foundation

/// Stub (plans/cmux-next/passwords.md, section 3.4); the rule lands next.
public nonisolated struct AgentExtensionAccess {
    let manifest: (String) -> [String: Any]?

    public init(manifest: @escaping (String) -> [String: Any]?) { self.manifest = manifest }

    public func blockers(_ extensions: [BrowserExtensionInfo], url: URL?) -> [BrowserExtensionInfo] { [] }

    public func matches(_ pattern: String, _ url: URL) -> Bool { false }
}
