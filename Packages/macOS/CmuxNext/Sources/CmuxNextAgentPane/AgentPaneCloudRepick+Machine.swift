import Foundation

/// A chat a `cloud.startChat` send opened on a Cloud machine: what the start was, from where, and
/// where it runs. The App keeps one per opened tab for its run (CmuxNextApp `CloudStartChat`), so
/// another machine picked before its first send runs (``AgentPaneCloudRepick``) moves only such a chat.
public nonisolated struct AgentPaneCloudStarted: Sendable, Equatable {
    public var start: AgentPaneCloudStart
    /// The chat's folder on this Mac (nil for a chat with no project, ``AgentPaneCloudStart/home``).
    public var chat: String?
    public var workspace: String?
    public var account: [String?]
    public var machineID: String

    public init(start: AgentPaneCloudStart, chat: String?, workspace: String?, account: [String?], machineID: String) {
        (self.start, self.chat, self.workspace, self.account, self.machineID) = (start, chat, workspace, account, machineID)
    }
}

extension AgentPaneCloudRepick {
    /// The account machine this repick names among `machines`: by id, else by the name acpmux lists
    /// it under (its title or slug, any case). Nil when none, or more than one, matches.
    public nonisolated func machineID(in machines: [(id: String, title: String, slug: String?)]) -> String? {
        if let id = machine { return machines.contains { $0.id == id } ? id : nil }
        guard let name = name?.lowercased() else { return nil }
        let matches = machines.filter { $0.title.lowercased() == name || $0.slug?.lowercased() == name }
        return matches.count == 1 ? matches[0].id : nil
    }
}
