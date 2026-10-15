import CmuxNextDesign

/// Debug Settings prototypes of the agent chat header (DEV and NIGHTLY).
nonisolated enum AgentChatHeaderTunables {
    /// Leo 2026-10-15: "Terminal: maybe not a toggle. Clicking the terminal button adds another
    /// terminal on the right each time." On, the header's Terminal runs in open mode
    /// (``AgentChatSplitToggles/open(_:cwd:url:chat:store:actions:)``) instead of toggling.
    static let terminalButtonAdds = Tunable<Bool>.toggle(
        "agentChat.terminalButtonAdds", .panes, "Terminal button adds a terminal",
        help: "Each click of an agent chat's Terminal button opens a new terminal right of the last one and focuses it, instead of closing the terminal it opened.",
        default: false, code: "AgentChatHeaderTunables.terminalButtonAdds")

    static var all: [TunableDescriptor] { [terminalButtonAdds.descriptor] }
}
