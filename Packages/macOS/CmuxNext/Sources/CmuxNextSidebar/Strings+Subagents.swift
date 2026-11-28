import Foundation

// A chat row's subagents: they draw no lines under the row, only the failed ones on the title line's failed mark.
extension Strings {
    /// A row's failed subagents, for VoiceOver (the title line draws them as its failed chip).
    static func subagentsFailed(_ count: Int) -> String {
        String(localized: "sidebar.subagents.stack.failed", defaultValue: "\(count) failed", bundle: .localizedModule)
    }
}
