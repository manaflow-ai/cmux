import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextWindowRules

/// `focusRing.*` palette actions: applied to `DesignSettings` at once, then
/// written to cmux.json through the validated `setSetting` path
/// (`AppActionContext.writeSetting`); the watcher reapplies them.
enum FocusRingHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        // Every pane ring, not just the focus ring (`DesignSettings.togglePaneRings`).
        registry.bind("focusRing.toggle", run: { _ in context.writeSettings("toggle pane rings", context.design.togglePaneRings()) })
        let design = context.design
        ActionTargetTitles.setPaletteSettingState("focusRing.toggle", in: registry) { design.showsAnyPaneRing }
        registry.bind("focusRing.style.ring", run: { _ in setStyle(.ring, context) })
        registry.bind("focusRing.style.glow", run: { _ in setStyle(.glow, context) })
        registry.bind("focusRing.singlePane.toggle", run: { _ in
            update(context, key: "showWhenSinglePane") { ring in
                ring.showsForSinglePane.toggle()
                return .bool(ring.showsForSinglePane)
            }
        })
        ActionTargetTitles.setPaletteSettingState("focusRing.singlePane.toggle", in: registry) { design.focusRing.showsForSinglePane }
    }

    /// Choosing a style also turns the ring on.
    private static func setStyle(_ style: FocusRingStyle, _ context: AppActionContext) {
        let design = context.design
        var ring = design.focusRing
        let wasEnabled = ring.enabled
        ring.style = style
        ring.enabled = true
        design.focusRing = ring
        // The edits are Rust's (cmux-window-rules `appearance::focus_ring_style`).
        let edits: [([String], JSONValue?)] = (WindowRules().focusRingStyle(style.rawValue, wasEnabled: wasEnabled) ?? []).map { edit in
            (edit.path, edit.flag.map(JSONValue.bool) ?? edit.text.map(JSONValue.string))
        }
        context.writeSettings("set focus ring style", edits)
    }

    private static func update(_ context: AppActionContext, key: String, _ change: (inout FocusRingSettings) -> JSONValue) {
        let design = context.design
        var ring = design.focusRing
        let value = change(&ring)
        design.focusRing = ring
        context.writeSetting("set focusRing.\(key)", ["focusRing", key], value)
    }
}
