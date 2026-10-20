import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings

/// `pane.setBackground`, `pane.setTint` and `pane.clearBackground`
/// (plans/cmux-next/pane-backgrounds-DESIGN.md): the one path the pane's right-click Appearance
/// folder, the palette, the CLI and MCP share. Values persist through `ThemeCoordinator`.
struct PaneBackgroundHandlers {
    let context: AppActionContext

    func bind(into registry: ActionRegistry) {
        let ctx = context
        registry.bind("pane.setBackground", invoke: { invocation in
            guard let pane = ctx.paneController(invocation) else { return }
            guard let raw = invocation["background"]?.stringValue ?? ctx.refuse(PaneBackgroundStrings.badBackground) else { return }
            let value = raw.trimmingCharacters(in: .whitespaces)
            guard Self.acceptsBackground(value) else { return ctx.refuse(PaneBackgroundStrings.badBackground) }
            guard ctx.services.themes.setPaneBackground(value, for: pane) else { return ctx.refuse(PaneBackgroundStrings.noDurablePane) }
        })
        registry.bind("pane.setTint", invoke: { invocation in
            guard let pane = ctx.paneController(invocation) else { return }
            guard let raw = invocation["color"]?.stringValue ?? ctx.refuse(PaneBackgroundStrings.badTint) else { return }
            let value = raw.trimmingCharacters(in: .whitespaces)
            let tint = PaneTint(value)
            guard tint != nil || value == "none" else { return ctx.refuse(PaneBackgroundStrings.badTint) }
            guard ctx.services.themes.setPaneTint(tint, for: pane) else { return ctx.refuse(PaneBackgroundStrings.noDurablePane) }
        })
        registry.bind("pane.clearBackground", invoke: { invocation in
            guard let pane = ctx.paneController(invocation) else { return }
            let themes = ctx.services.themes
            guard themes.setPaneBackground(nil, for: pane), themes.setPaneTint(nil, for: pane) else {
                return ctx.refuse(PaneBackgroundStrings.noDurablePane)
            }
        })
    }

    /// The values `appearance.background` takes, plus `inherit`.
    static func acceptsBackground(_ value: String) -> Bool {
        value == "inherit" || value == "none" || value == BackdropSelectionSetting.dailyID
            || BackdropSelection(id: value) != nil
    }
}
