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
    /// When the chat opened.
    public var at: Date

    public init(start: AgentPaneCloudStart, chat: String?, workspace: String?, account: [String?], machineID: String, at: Date = Date()) {
        (self.start, self.chat, self.workspace, self.account, self.machineID, self.at) = (start, chat, workspace, account, machineID, at)
    }

    /// How soon after its start a Cloud chat that goes counts as one that never got going: its prompt goes
    /// back into the Mac tab's composer (cmux#55066). A chat that went later says only that it ended.
    public static let freshEnd: TimeInterval = 10 * 60

    /// The seed of the Mac tab whose Cloud chat `started` (shown there in place) went at `now`: its new page
    /// says the Cloud chat on `machine` ended, with the start's prompt back in its composer when the chat went
    /// within ``freshEnd`` of its start. Nil without a start this run (a repick moved it on): no notice.
    @MainActor public static func endedSeed(_ started: Self?, machine: String?, now: Date = Date()) -> AgentPaneSeedSource? {
        guard let started else { return nil }
        let fresh = now.timeIntervalSince(started.at) < freshEnd && started.start.task.contains { !$0.isWhitespace }
        let seed = AgentPaneSeedSource(AgentPaneSeed(cwd: started.chat, draft: fresh ? started.start.task : nil))
        seed.cloudChatEnded = (machine, fresh)
        return seed
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
