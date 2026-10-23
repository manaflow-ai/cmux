// Import suggestion cards (CmuxNextImportCards): what this Mac has that cmux can bring over,
// listed in Settings › Import (never on Home or New Tab). Titles live in ImportActions.xcstrings. The CLI and
// agents list the cards, press a card's button, and raise a card for a site another browser is
// signed into (`cmux import suggest --browser chrome --site github.com --reason …`): a raised card
// reads nothing until the person clicks Import on it.

nonisolated enum ImportActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        let plan = ActionSurfacePlan(palette: .exempt(.noObject), cli: .offered, contextMenuExemption: .noObject)
        var list = ActionDescriptor(
            id: "import.list", title: t("action.import.list", "List Import Suggestions"),
            keywords: ["import", "browser", "chrome", "safari", "arc", "claude", "codex", "iterm", "ghostty", "classic"],
            category: .settings, symbol: "square.and.arrow.down", surfaces: [.keyboard], cliName: "import list", surfacePlan: plan)
        list.waitsForResult = true
        let card = ActionDescriptor(
            id: "import.card", title: t("action.import.card", "Press an Import Card's Button"),
            keywords: ["import", "card", "dismiss", "resume"], category: .settings, symbol: "square.and.arrow.down", surfaces: [.keyboard],
            arguments: [
                ActionArgument(name: "id", title: t("argument.import.card.id", "Card"), kind: .string),
                ActionArgument(name: "action", title: t("argument.import.card.action", "Button"), kind: .string),
            ],
            cliName: "import card", surfacePlan: plan)
        let suggest = ActionDescriptor(
            id: "import.suggest", title: t("action.import.suggest", "Suggest Importing a Site's Cookies"),
            keywords: ["import", "cookies", "sign in", "login", "suggest", "chief"], category: .settings, symbol: "key", surfaces: [.keyboard],
            arguments: [
                ActionArgument(name: "browser", title: t("argument.import.suggest.browser", "Browser"), kind: .string),
                ActionArgument(name: "site", title: t("argument.import.suggest.site", "Site"), kind: .string),
                ActionArgument(name: "reason", title: t("argument.import.suggest.reason", "Reason"), kind: .string, isRequired: false),
            ],
            cliName: "import suggest", surfacePlan: plan)
        let open = ActionDescriptor(
            id: "import.open", title: t("action.import.open", "Import from Other Apps…"),
            keywords: ["import", "browser", "chrome", "safari", "arc", "claude", "codex", "iterm", "ghostty", "classic", "migrate"],
            category: .settings, symbol: "square.and.arrow.down", surfaces: [.palette], cliName: "import open",
            surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject))
        return [list, card, suggest, open]
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "ImportActions", bundle: .module)
    }
}
