import CmuxNextDesign

/// Debug Settings of cmux:// links (DEV and NIGHTLY only).
nonisolated struct LinkTunables {
    static let section = TunableSection(id: "links", title: "Links", symbol: "link", order: 47)

    /// `cmux://agent/<harness>/<session>` (hq#2555). On: such a link reveals only a session this
    /// app can already reach, so the reach itself is the authorization.
    static let agentLinks = Tunable<Bool>.toggle(
        "links.agentLinks", section, "Agent links",
        help: "cmux://agent/<harness>/<session> links reveal a session this app already shows. Off refuses them.",
        default: true, code: "LinkTunables.agentLinks")

    static var all: [TunableDescriptor] { [agentLinks.descriptor] }
}
