public import Foundation

/// Pages an agent-driven tab never loads, shows or scripts
/// (plans/cmux-next/passwords.md, section 2). Stub: the rule lands next.
public nonisolated enum AgentURLPolicy {
    public static func refuses(_ url: URL) -> Bool { refuses(url.absoluteString) }

    public static func refuses(_ text: String) -> Bool { false }
}
