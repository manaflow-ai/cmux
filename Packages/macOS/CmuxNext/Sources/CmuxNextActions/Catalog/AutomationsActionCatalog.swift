// Automations (docs/automations-platonic-ideal.md section 8, option A): the Automations page, from
// Cmd+Shift+P, the sidebar's Automations item and the CLI. Making, running and pausing an
// automation stay `cmux automation …` and the Chief's tool; the page's buttons call the same ops.
// Titles live in ActionCatalog.xcstrings.

nonisolated enum AutomationsActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "automations.show", title: t("action.automations.show", "Automations"),
                keywords: ["automations", "scheduled", "schedule", "cron", "jobs", "tasks", "recurring", "routines", "every morning"],
                category: .window, symbol: "clock.badge.checkmark", surfaces: [.palette, .keyboard],
                cliName: "automation show-page",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
        ]
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "ActionCatalog", bundle: .module)
    }
}
