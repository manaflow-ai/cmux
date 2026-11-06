import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings

/// `focusRing.*` palette actions: applied to `DesignSettings` at once, then
/// written to cmux.json through the validated `setSetting` path
/// (`AppActionContext.writeSetting`); the watcher reapplies them.
enum FocusRingHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("focusRing.toggle", run: { _ in toggle(context) })
        let design = context.design
        ActionTargetTitles.setPaletteState("focusRing.toggle", in: registry) { showsAnyRing(design) }
        registry.bind("focusRing.style.ring", run: { _ in setStyle(.ring, context) })
        registry.bind("focusRing.style.glow", run: { _ in setStyle(.glow, context) })
        registry.bind("focusRing.singlePane.toggle", run: { _ in
            update(context, key: "showWhenSinglePane") { ring in
                ring.showsForSinglePane.toggle()
                return .bool(ring.showsForSinglePane)
            }
        })
        ActionTargetTitles.setPaletteState("focusRing.singlePane.toggle", in: registry) { design.focusRing.showsForSinglePane }
    }

    /// Whether any pane ring can draw: the focus ring, or the unread ring on a terminal or an agent
    /// chat (`notifications.attention.terminals`, `.agentChats`). Toggle Focus Ring reads and turns
    /// off all of them: the person sees one ring on a pane and asks for it to go (Leo 2026-11-06:
    /// "WHY DOESN'T THE COMMAND PALETTE TOGGLE FOR FOCUS RINGS WORK FOR TURNING IT OFF").
    static func showsAnyRing(_ design: DesignSettings) -> Bool {
        design.focusRing.enabled || design.attention.drawsAnyRing
    }

    /// Off: no pane ring of any kind (the unread dot on the tab and the sidebar row stays). On: the
    /// focus ring; the unread rings come back from Settings, Notifications.
    private static func toggle(_ context: AppActionContext) {
        let design = context.design
        guard showsAnyRing(design) else {
            return update(context, key: "enabled") { ring in
                ring.enabled = true
                return .bool(true)
            }
        }
        var ring = design.focusRing
        ring.enabled = false
        design.focusRing = ring
        var attention = design.attention
        attention.terminalRing = .none
        attention.agentChatRing = .none
        design.attention = attention
        context.writeSettings("turn pane rings off", [
            (["focusRing", "enabled"], .bool(false)),
            (["notifications", "attention", "terminals"], .string(FocusRingStyle.none.rawValue)),
            (["notifications", "attention", "agentChats"], .string(FocusRingStyle.none.rawValue)),
        ])
    }

    /// Choosing a style also turns the ring on.
    private static func setStyle(_ style: FocusRingStyle, _ context: AppActionContext) {
        let design = context.design
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
        let design = context.design
        var ring = design.focusRing
        let value = change(&ring)
        design.focusRing = ring
        context.writeSetting("set focusRing.\(key)", ["focusRing", key], value)
    }
}
