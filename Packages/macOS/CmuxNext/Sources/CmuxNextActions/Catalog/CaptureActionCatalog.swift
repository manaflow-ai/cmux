// Capture… (plans/cmux-next/capture-bar-DESIGN.md): the capture bar on the composer of the chat the
// person works in, for a screenshot (region, window, pane, the cmux window) or a recording of the
// cmux window. Ctrl-Shift-Cmd-5 is macOS's Shift-Cmd-5 capture toolbar plus Ctrl, which no cmux,
// terminal or system shortcut takes. A bar a person drives, so no CLI verb: scripts attach files
// with the composer's own verbs. Titles live in ActionCatalog.xcstrings.

nonisolated enum CaptureActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "capture.open", title: t("action.capture.open", "Capture…"),
                keywords: ["screenshot", "screen recording", "record", "video", "capture", "share screen", "attach"],
                defaultShortcut: Shortcut("5", modifiers: [.control, .shift, .command]),
                category: .agents, symbol: "camera.viewfinder", surfaces: [.palette, .keyboard, .menu],
                targets: [.pane], mainMenu: .view,
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .guiOnly)
            ),
        ]
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "ActionCatalog", bundle: .module)
    }
}
