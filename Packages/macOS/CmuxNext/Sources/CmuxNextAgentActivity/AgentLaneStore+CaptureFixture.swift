#if DEBUG
public import Foundation

/// `debug.sidebar_agent_fixture` (captures): fixture agent sessions of several harnesses (Codex, Claude,
/// and one with no registered mark) so a capture shows the Priority view and the Chief's subagents
/// without a live acpmux. The next watch page replaces them.
extension AgentLaneStore {
    /// The fixture harness with no registered brand mark.
    public static let captureUnregisteredHarness = "acme-agent"

    /// This Mac's store: one chat in each Priority state across the fixture harnesses. Returns the count.
    @discardableResult
    public func fillCaptureChats(now: Date = Date()) -> Int {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let acme = Self.captureUnregisteredHarness
        let chats = [
            AgentActivityLane(id: "fx-codex-asks", name: "fx-codex-asks", title: "Review the sidebar grid", peer: nil, parent: nil,
                              state: .input, since: ago(3), error: nil, harness: "codex", step: "Waiting for approval", project: "cmux"),
            AgentActivityLane(id: "fx-claude-works", name: "fx-claude-works", title: "Fix the login redirect", peer: nil, parent: nil,
                              state: .working, since: ago(12), error: nil, harness: "claude", step: "Running tests", project: "web"),
            AgentActivityLane(id: "fx-acme-failed", name: "fx-acme-failed", title: "Port the settings page", peer: nil, parent: nil,
                              state: .failed, since: ago(8), error: "Credit balance too low", harness: acme, project: "cmux"),
            AgentActivityLane(id: "fx-codex-done", name: "fx-codex-done", title: "Write the release notes", peer: nil, parent: nil,
                              state: .idle, since: ago(20), error: nil, harness: "codex", unread: true, project: "docs"),
            AgentActivityLane(id: "fx-acme-works", name: "fx-acme-works", title: "Profile the transcript", peer: nil, parent: nil,
                              state: .working, since: ago(30), error: nil, harness: acme, step: "Reading traces", project: "cmux"),
        ]
        lanes = Dictionary(uniqueKeysWithValues: chats.map { ($0.id, $0) })
        return chats.count
    }

    /// The Chief's store: two untitled subagents (their title is their acpmux name) and one with a task title.
    @discardableResult
    public func fillCaptureSubagents(now: Date = Date()) -> Int {
        let parent = "optchat-chief:f1x7ure0"
        let subagents = [("a2", "claude", nil), ("a3", "codex", nil), ("a4", Self.captureUnregisteredHarness, "Inspector")]
            .map { (number: String, harness: String, task: String?) in
                let name = "optchat-sub-f1x7ure0-" + number
                return AgentActivityLane(id: "fx-" + name, name: name, title: task ?? name, peer: nil, parent: parent, state: .working,
                                         since: now.addingTimeInterval(-120), error: nil, harness: harness)
            }
        lanes = Dictionary(uniqueKeysWithValues: subagents.map { ($0.id, $0) })
        return subagents.count
    }
}
#endif
