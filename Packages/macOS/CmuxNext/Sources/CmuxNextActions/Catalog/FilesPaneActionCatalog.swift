// Files pane (u2360, plans/finder-parity/PARITY.md): a native Finder-parity
// file browser as an internal page tab (`local-page:files-pane:<uuid>`).
// Titles live in FilesPaneActions.xcstrings.

nonisolated enum FilesPaneActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "files.open", title: t("action.files.open", "Open Files"),
                keywords: ["files", "finder", "folder", "browse", "file manager", "explorer", "directory", "home"],
                category: .pane, symbol: "folder", surfaces: [.palette, .keyboard],
                surfacePlan: ActionSurfacePlan(
                    // Opens a new tab in the active window. Agents list and
                    // change files with their own tools, so there is no CLI verb.
                    cli: .exempt(.guiOnly), contextMenuExemption: .noObject)
            ),
        ]
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "FilesPaneActions", bundle: .module)
    }
}
