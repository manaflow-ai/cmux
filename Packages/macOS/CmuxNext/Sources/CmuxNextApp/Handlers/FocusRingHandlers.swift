import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings

/// `focusRing.*` palette actions: applied to `DesignSettings` at once, then
/// written to cmux.json through the validated `setSetting` path
/// (`AppActionContext.writeSetting`); the watcher reapplies them.
enum FocusRingHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("focusRing.toggle", run: { _ in
            update(context, key: "enabled") { ring in
                ring.enabled.toggle()
                return .bool(ring.enabled)
            }
        })
        registry.bind("focusRing.style.ring", run: { _ in setStyle(.ring, context) })
        registry.bind("focusRing.style.glow", run: { _ in setStyle(.glow, context) })
        registry.bind("focusRing.singlePane.toggle", run: { _ in
            update(context, key: "showWhenSinglePane") { ring in
                ring.showsForSinglePane.toggle()
                return .bool(ring.showsForSinglePane)
            }
        })
    }

    /// Choosing a style also turns the ring on.
    private static func setStyle(_ style: FocusRingStyle, _ context: AppActionContext) {
        let design = DesignSettings.shared
        var ring = design.focusRing
        let wasEnabled = ring.enabled
        ring.style = style
        ring.enabled = true
        design.focusRing = ring
        var edits: [([String], JSONValue?)] = [(["focusRing", "style"], .string(style.rawValue))]
        if !wasEnabled { edits.append((["focusRing", "enabled"], .bool(true))) }
        context.writeSettings("set focus ring style", edits)
    }

    private static func update(_ context: AppActionContext, key: String, _ change: (inout FocusRingSettings) -> JSONValue) {
        let design = DesignSettings.shared
        var ring = design.focusRing
        let value = change(&ring)
        design.focusRing = ring
        context.writeSetting("set focusRing.\(key)", ["focusRing", key], value)
    }
}
