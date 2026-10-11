// The command palette's own keys (R59 fold): each palette command is an
// action whose default keys are binding table entries with a `when` over the
// palette's state (`KeyBindingDefaults.paletteKeys`), so the Keyboard
// Shortcuts page lists them and cmux.json / keybindings.json can rebind or
// remove them. `PaletteKeyMap` resolves a key through those entries. Next
// and previous item stay `commandPaletteNext` / `commandPalettePrevious`.
// Titles live in ActionCatalog.xcstrings.

nonisolated enum PaletteKeyActionCatalog: ActionCatalogGroup {
    /// Every palette key action, with its English title and symbol.
    static let actions: [(id: ActionID, key: StaticString, title: String.LocalizationValue, symbol: String)] = [
        ("paletteKey.firstItem", "action.paletteKey.firstItem", "Palette: First Item", "arrow.up.to.line"),
        ("paletteKey.lastItem", "action.paletteKey.lastItem", "Palette: Last Item", "arrow.down.to.line"),
        ("paletteKey.pageUp", "action.paletteKey.pageUp", "Palette: Page Up", "chevron.up.2"),
        ("paletteKey.pageDown", "action.paletteKey.pageDown", "Palette: Page Down", "chevron.down.2"),
        ("paletteKey.submit", "action.paletteKey.submit", "Palette: Run Item", "return"),
        ("paletteKey.submitAlternate", "action.paletteKey.submitAlternate", "Palette: Run Item's Other Command", "return"),
        ("paletteKey.openActions", "action.paletteKey.openActions", "Palette: Show Actions", "list.bullet"),
        ("paletteKey.closeActions", "action.paletteKey.closeActions", "Palette: Hide Actions", "list.bullet"),
        ("paletteKey.toggleActions", "action.paletteKey.toggleActions", "Palette: Show or Hide Actions", "list.bullet"),
        ("paletteKey.escape", "action.paletteKey.escape", "Palette: Clear or Close", "escape"),
        ("paletteKey.enterRow", "action.paletteKey.enterRow", "Palette: Open Item", "chevron.right"),
        ("paletteKey.leaveLevel", "action.paletteKey.leaveLevel", "Palette: Up One Level", "chevron.left"),
        ("paletteKey.back", "action.paletteKey.back", "Palette: Back", "chevron.backward"),
        ("paletteKey.filterDeleteBackward", "action.paletteKey.filterDeleteBackward", "Palette: Delete Filter Character", "delete.left"),
        ("paletteKey.closeItem", "action.paletteKey.closeItem", "Palette: Close Item's Object", "xmark"),
    ]

    static func descriptors() -> [ActionDescriptor] {
        actions.map { action in
            ActionDescriptor(
                id: action.id, title: String(localized: action.key, defaultValue: action.title, bundle: .module),
                keywords: ["palette"], category: .window, symbol: action.symbol, surfaces: [.keyboard], requires: [.paletteOpen],
                surfacePlan: ActionSurfacePlan(palette: .exempt(.paletteInternal), cli: .exempt(.liveInput),
                                               contextMenuExemption: .paletteInternal)
            )
        }
    }
}
