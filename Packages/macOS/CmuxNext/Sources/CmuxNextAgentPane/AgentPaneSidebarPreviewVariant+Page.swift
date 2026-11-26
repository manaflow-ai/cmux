public import CmuxNextSettings
import Foundation

/// The native Debug Settings sidebar preview choice reaches the page as a host event and as the
/// equivalent old-host bridge call. A layout customization may override it after this event.
extension AgentPageEvent {
    /// The sidebar preview baseline (`card`, `quiet` or `outline`).
    public static func sidebarPreviewVariant(_ variant: AgentPaneSidebarPreviewVariant) -> AgentPageEvent {
        AgentPageEvent(kind: "sidebarPreviewVariant", value: .string(variant.rawValue))
    }
}

/// Pushes the native sidebar preview baseline to an agent page.
extension AgentPaneSidebarPreviewVariant {
    /// Gives `view` the current native choice when it changes.
    @MainActor public func push(to view: AgentPaneView) {
        guard self != view.model.sidebarPreviewVariant else { return }
        view.model.sidebarPreviewVariant = self
        replay(to: view)
    }

    /// Replays the current choice after an old-host page installs its bridge.
    @MainActor public func replay(to view: AgentPaneView) {
        let event = AgentPageEvent.sidebarPreviewVariant(self)
        let value = JSONValue.string(rawValue).compactText
        view.deliver([event], scripts: ["window.cmuxAcpmuxBridge?.applySidebarPreviewVariant?.(\(value));"])
    }
}
