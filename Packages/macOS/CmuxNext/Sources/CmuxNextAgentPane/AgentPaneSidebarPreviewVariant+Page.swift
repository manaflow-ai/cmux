public import CmuxNextSettings
import Foundation

/// The native Debug Settings sidebar preview choice reaches the page as a host event. A layout
/// customization may override it after this event.
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

    /// Sends the current choice to `view`'s page.
    @MainActor public func replay(to view: AgentPaneView) {
        view.deliver([AgentPageEvent.sidebarPreviewVariant(self)])
    }
}
