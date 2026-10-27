import AppKit
import CmuxNextActions

extension ActionTargetTitles {
    /// Applies the target's title, its toggle state and the target-aware
    /// disabled reason (Chromium in a build without CEF) to a context menu item.
    static func decorate(_ item: NSMenuItem, id: ActionID, invocation: ActionInvocation, in registry: ActionRegistry) {
        let action = registry.action(for: id)
        if let title = action?.targetTitle?(invocation) { item.title = title }
        if let on = action?.targetState?(invocation) { item.state = on ? .on : .off }
        if let reason = ActionTargetReasons.reason(for: id, invocation: invocation, in: registry) {
            if #available(macOS 14.4, *) { item.subtitle = reason }
            item.toolTip = reason
        }
    }
}
