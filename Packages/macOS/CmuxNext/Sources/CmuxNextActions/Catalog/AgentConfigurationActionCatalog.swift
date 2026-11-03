/// Typed setters for a focused (or explicitly targeted) agent chat's live
/// acpmux configuration. The App supplies dynamic suggestions from the
/// connected session; the values are still passed as stable ids so the same
/// action is callable from the palette, CLI and MCP.
nonisolated enum AgentConfigurationActionCatalog: ActionCatalogGroup {
    private static func text(_ key: StaticString, _ fallback: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: fallback, table: "AgentConfigurationActions", bundle: .module)
    }

    private static var modelArgument: ActionArgument { ActionArgument(
        name: "model",
        title: text("argument.agentPane.model", "Model"),
        kind: .string,
        suggestions: ActionSuggestions(source: ActionSuggestions.agentModels, pinned: [],
                                       otherTitle: text("argument.agentPane.model.other", "Enter Model ID…"))
    ) }
    private static var effortArgument: ActionArgument { ActionArgument(
        name: "effort",
        title: text("argument.agentPane.effort", "Effort"),
        kind: .string,
        suggestions: ActionSuggestions(source: ActionSuggestions.agentEfforts, pinned: [],
                                       otherTitle: text("argument.agentPane.effort.other", "Enter Effort…"))
    ) }
    private static var modeArgument: ActionArgument { ActionArgument(
        name: "mode",
        title: text("argument.agentPane.mode", "Mode"),
        kind: .string,
        suggestions: ActionSuggestions(source: ActionSuggestions.agentModes, pinned: [],
                                       otherTitle: text("argument.agentPane.mode.other", "Enter Mode…"))
    ) }

    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "agentPane.setModel",
                title: text("action.agentPane.setModel", "Set Agent Chat Model…"),
                keywords: ["agent", "chat", "model", "models", "harness", "provider", "llm", "switch", "change", "set"],
                category: .agents,
                symbol: "cpu",
                surfaces: [.palette],
                requires: [.agentPaneFocused],
                arguments: [modelArgument],
                targets: [.pane, .tab, .agentChat],
                cliName: "agent set-model",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noTargetSurface)
            ),
            ActionDescriptor(
                id: "agentPane.setEffort",
                title: text("action.agentPane.setEffort", "Set Agent Chat Effort…"),
                keywords: ["agent", "chat", "effort", "reasoning", "thinking", "depth", "fast", "slow", "set", "change"],
                category: .agents,
                symbol: "gauge.with.dots.needle.67percent",
                surfaces: [.palette],
                requires: [.agentPaneFocused],
                arguments: [effortArgument],
                targets: [.pane, .tab, .agentChat],
                cliName: "agent set-effort",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noTargetSurface)
            ),
            ActionDescriptor(
                id: "agentPane.setMode",
                title: text("action.agentPane.setMode", "Set Agent Chat Mode…"),
                keywords: ["agent", "chat", "mode", "permission", "access", "plan", "read-only", "full access", "set", "change"],
                category: .agents,
                symbol: "slider.horizontal.3",
                surfaces: [.palette],
                requires: [.agentPaneFocused],
                arguments: [modeArgument],
                targets: [.pane, .tab, .agentChat],
                cliName: "agent set-mode",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noTargetSurface)
            ),
        ]
    }
}
