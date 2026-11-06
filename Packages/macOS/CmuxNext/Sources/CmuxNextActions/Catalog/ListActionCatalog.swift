// List navigation (R85): Next Item / Previous Item move the selection of
// the focused list-like control. Their keys (Ctrl-N, Ctrl-J, Ctrl-P,
// Ctrl-K) are default entries with `when: listFocus`
// (`KeyBindingDefaults.listNavigation`), not catalog shortcuts. Titles live
// in ActionCatalog.xcstrings.

nonisolated enum ListActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "list.next",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.list.next") + "\u{E002}" + String(localized: "action.list.next", defaultValue: "Next Item", bundle: .module)),
                keywords: ["list", "down", "next", "select"], category: .window, symbol: "chevron.down",
                surfaces: [.keyboard],
                surfacePlan: ActionSurfacePlan(palette: .exempt(.liveInput), cli: .exempt(.liveInput),
                                               contextMenuExemption: .liveInput)
            ),
            ActionDescriptor(
                id: "list.previous",
                title: ("\u{E000}Localizable\u{E001}" + String(describing: "action.list.previous") + "\u{E002}" + String(localized: "action.list.previous", defaultValue: "Previous Item", bundle: .module)),
                keywords: ["list", "up", "previous", "select"], category: .window, symbol: "chevron.up",
                surfaces: [.keyboard],
                surfacePlan: ActionSurfacePlan(palette: .exempt(.liveInput), cli: .exempt(.liveInput),
                                               contextMenuExemption: .liveInput)
            ),
        ]
    }
}
