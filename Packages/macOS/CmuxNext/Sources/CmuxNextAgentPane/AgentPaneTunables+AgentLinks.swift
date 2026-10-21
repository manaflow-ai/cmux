public import CmuxNextDesign
import CmuxNextPages

nonisolated extension AgentPaneTunables {
    /// `cmux://agent/<harness>/<session>` (hq#2555). On: such a link reveals only a session this
    /// app can already reach, so the reach itself is the authorization. Off refuses them.
    public static let agentLinks = Tunable<Bool>.toggle(
        "links.agentLinks", PageTunables.section, "Agent links",
        help: "cmux://agent links reveal a session this app already shows. Off refuses them.",
        default: true, code: "AgentPaneTunables.agentLinks")
}
