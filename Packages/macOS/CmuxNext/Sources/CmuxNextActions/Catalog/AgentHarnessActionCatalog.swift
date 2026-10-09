// Bring your own harness (BRING-YOUR-OWN-HARNESS H2): add, remove, restore and check an ACP
// agent. One handler per action (AgentHarnessHandlers), so the palette, the CLI (`cmux agent
// harness ...`), MCP (one tool per CLI verb), Settings > Agents and the model picker's + all run
// the same daemon request. Titles live in ActionCatalog.xcstrings.

nonisolated enum AgentHarnessActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        let id = ActionArgument(name: "id", title: t("argument.agent.harness.id", "Agent"), kind: .string, isRequired: false)
        let protocols = ActionArgumentKind.enumeration([
            ActionEnumCase(value: "acp", title: t("argument.agent.harness.protocol.acp", "ACP")),
            ActionEnumCase(value: "terminal", title: t("argument.agent.harness.protocol.terminal", "Terminal")),
        ])
        return [
            // Without arguments (the palette, the model picker's +) it opens Settings > Agents >
            // Add; with a command, registry agent or example it writes the profile.
            ActionDescriptor(
                id: "agent.harness.add", title: t("action.agent.harness.add", "Add ACP Agent…"),
                keywords: ["agent", "harness", "acp", "acpmux", "custom", "bring your own", "add", "install", "profile"],
                category: .agents, symbol: "plus.app",
                arguments: [
                    ActionArgument(name: "command", title: t("argument.agent.harness.command", "Command"), kind: .string, isRequired: false),
                    ActionArgument(name: "args", title: t("argument.agent.harness.args", "Arguments"), kind: .string, isRequired: false),
                    ActionArgument(name: "registry", title: t("argument.agent.harness.registry", "Registry Agent"), kind: .string, isRequired: false),
                    ActionArgument(name: "example", title: t("argument.agent.harness.example", "Example"), kind: .string, isRequired: false),
                    id,
                    ActionArgument(name: "name", title: t("argument.agent.harness.name", "Name"), kind: .string, isRequired: false),
                    ActionArgument(name: "protocol", title: t("argument.agent.harness.protocol", "Protocol"), kind: protocols, isRequired: false),
                    ActionArgument(name: "replace", title: t("argument.agent.harness.replace", "Replace"), kind: .bool, isRequired: false),
                ],
                cliName: "agent harness add",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "agent.harness.addFromRegistry", title: t("action.agent.harness.addFromRegistry", "Add Agent from ACP Registry…"),
                keywords: ["agent", "harness", "acp", "registry", "install", "gemini", "cursor", "goose", "add"],
                category: .agents, symbol: "shippingbox",
                // Opens the registry list in Settings; scripts pass `registry` to agent.harness.add.
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "agent.harness.remove", title: t("action.agent.harness.remove", "Remove Agent…"),
                keywords: ["agent", "harness", "acp", "remove", "delete", "uninstall", "profile"],
                category: .agents, symbol: "minus.square",
                arguments: [id],
                cliName: "agent harness remove",
                // Undoable (RECOVERABLE-BY-DEFAULT): the profile moves aside and agent.harness.restore
                // puts it back, so no confirmation.
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "agent.harness.restore", title: t("action.agent.harness.restore", "Restore Removed Agent"),
                keywords: ["agent", "harness", "restore", "undo", "removed"],
                category: .agents, symbol: "arrow.uturn.backward",
                arguments: [ActionArgument(name: "backup", title: t("argument.agent.harness.backup", "Backup"), kind: .string, isRequired: false)],
                cliName: "agent harness restore",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "agent.harness.doctor", title: t("action.agent.harness.doctor", "Check Agent…"),
                keywords: ["agent", "harness", "acp", "doctor", "check", "test", "diagnose", "handshake"],
                category: .agents, symbol: "stethoscope",
                arguments: [id],
                cliName: "agent harness doctor",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
        ]
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, bundle: .module)
    }
}
