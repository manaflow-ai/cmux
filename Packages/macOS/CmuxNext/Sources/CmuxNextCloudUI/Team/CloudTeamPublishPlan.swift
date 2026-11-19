import Foundation

/// What the publisher tells the team about one of the person's Cloud chats or workspaces
/// (`team.cloud.session.publish`): one input per chat tab on a Cloud machine of theirs.
public nonisolated struct CloudTeamPublishInput: Equatable, Sendable {
    public var ref: CloudTeamSessionStore.Ref
    public var title: String
    public var workspace: String?
    public var harness: String?
    public var machineState: String
    public var activity: String

    public init(ref: CloudTeamSessionStore.Ref, title: String, workspace: String?, harness: String?, machineState: String, activity: String) {
        self.ref = ref
        self.title = title
        self.workspace = workspace
        self.harness = harness
        self.machineState = machineState
        self.activity = activity
    }

    /// TeamDO's activity for an agent's state (`AgentState`: working, blocked, idle, done, unknown)
    /// and whether its tab asks for the person.
    public static func activity(agentState: String?, attention: Bool) -> String {
        if attention || agentState == "blocked" { return "needs_attention" }
        return agentState == "working" ? "working" : "idle"
    }

    /// TeamDO's machine state for a Cloud machine's status (`CloudMachine.Status`).
    public static func machineState(status: String, connected: Bool) -> String {
        switch status {
        case "running": connected ? "running" : "unresponsive"
        case "paused", "pausing": "asleep"
        case "starting", "provisioning": "waking"
        case "destroyed", "deleting": "gone"
        default: "unresponsive"
        }
    }
}

/// Which inputs to publish: only those whose title, activity or machine state changed since the
/// last publish that TeamDO took, so a burst of tab changes is one publish per changed chat and an
/// unchanged sidebar sends nothing. A refused publish is forgotten and tried again on the next change.
public nonisolated struct CloudTeamPublishPlan: Sendable {
    private var published: [String: CloudTeamPublishInput] = [:]
    private var activityAt: [String: Int] = [:]

    public init() {}

    /// The inputs to send now, each with its `last_activity_at` (ms): `now` when its activity
    /// changed, else the time its activity last changed.
    public mutating func changes(_ inputs: [CloudTeamPublishInput], now: Int) -> [(CloudTeamPublishInput, Int)] {
        var out: [(CloudTeamPublishInput, Int)] = []
        for input in inputs where published[input.ref.key] != input {
            let key = input.ref.key
            if published[key]?.activity != input.activity || activityAt[key] == nil { activityAt[key] = now }
            published[key] = input
            out.append((input, activityAt[key] ?? now))
        }
        return out
    }

    /// A publish TeamDO refused (or that never reached it): send it again on the next change.
    public mutating func forget(_ key: String) {
        published[key] = nil
    }

    /// Signed out or another team: everything is sent again for the next account.
    public mutating func reset() {
        published = [:]
        activityAt = [:]
    }
}
