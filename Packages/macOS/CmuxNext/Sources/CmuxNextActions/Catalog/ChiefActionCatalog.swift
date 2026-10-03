// Chief experiment (plans/cmux-next/chief.md; branch feat-cmux-next-chief
// only): opens the chief conversation tab. The sidebar's injected item runs
// this action, so the palette, the CLI (`cmux chief show`) and agents reach
// the same path. Titles live in ChiefActions.xcstrings.

nonisolated enum ChiefActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "chief.show", title: t("action.chief.show", "Chief (experiment)"),
                keywords: ["chief", "manager", "agent", "memory", "home", "experiment"],
                category: .agents, symbol: "brain", surfaces: [.palette, .keyboard],
                cliName: "chief show",
                surfacePlan: ActionSurfacePlan(
                    // A tab of the active window; automation opens it without moving focus.
                    cli: .offered, contextMenuExemption: .noObject)
            ),
        ]
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "ChiefActions", bundle: .module)
    }
}
