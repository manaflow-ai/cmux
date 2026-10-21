/// An existing acpmux session's chat as a tab (`cmux agent open-tab SESSION`): the tab that shows
/// it already, else a new tab beside the chat of session `beside` (a sub-session beside its
/// parent), else in `workspace`'s last focused pane, else the focused pane. The sidebar's nested
/// sub-sessions and a chat page's open offers take the same path.
nonisolated enum AgentSessionActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "agent.openSessionTab",
                title: String(localized: "action.agent.openSessionTab", defaultValue: "Open Agent Session in Tab", bundle: .module),
                keywords: ["agent", "session", "acpmux", "subagent", "sub-session", "tab", "chat"], category: .agents,
                symbol: "bubble.left.and.text.bubble.right", surfaces: [.keyboard],
                arguments: [
                    ActionArgument(name: "session", title: String(localized: "argument.agent.session", defaultValue: "Session", bundle: .module),
                                   kind: .string),
                    ActionArgument(name: "beside", title: String(localized: "argument.agent.besideSession", defaultValue: "Beside Session", bundle: .module),
                                   kind: .string, isRequired: false),
                    CatalogArgument.workspaceWorkspace.optional,
                ],
                cliName: "agent open-tab",
                surfacePlan: ActionSurfacePlan(palette: .exempt(.noObject), cli: .offered, contextMenuExemption: .noObject)
            ),
        ]
    }
}
