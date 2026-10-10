// The tab icon actions (ICON-PICKER-ALL-EMOJI-AND-SF-SYMBOLS): one path for the
// tab context menu, the palette, the CLI (`cmux tab set-icon`) and MCP. An `icon`
// argument sets it; no argument opens the shared icon picker at the tab.

nonisolated enum TabIconActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "tab.setIcon",
                title: String(localized: "action.tab.setIcon", defaultValue: "Set Tab Icon…", bundle: .module),
                keywords: ["tab", "icon", "emoji", "symbol"], category: .tab, symbol: "face.smiling",
                surfaces: [.palette, .contextMenu], arguments: [CatalogArgument.iconString.optional], targets: [.tab],
                cliName: "tab set-icon"
            ),
            ActionDescriptor(
                id: "tab.clearIcon",
                title: String(localized: "action.tab.clearIcon", defaultValue: "Remove Tab Icon", bundle: .module),
                keywords: ["tab", "icon", "emoji", "reset"], category: .tab, symbol: "circle.dashed",
                surfaces: [.palette, .contextMenu], targets: [.tab], cliName: "tab clear-icon"
            ),
        ]
    }
}
