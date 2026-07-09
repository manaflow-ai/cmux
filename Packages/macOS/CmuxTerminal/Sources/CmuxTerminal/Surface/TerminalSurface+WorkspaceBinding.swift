public import Foundation
public import GhosttyKit
public import CmuxTerminalCore

extension TerminalSurface {
    /// Whether the surface stays open after its startup command exits.
    public func debugWaitAfterCommand() -> Bool {
        configTemplate?.waitAfterCommand ?? false
    }

    /// The ghostty launch context the surface was created with.
    public var launchContext: ghostty_surface_context_e {
        surfaceContext
    }

    /// Rebinds the surface (and its views) to a new owning workspace id.
    @MainActor
    public func updateWorkspaceId(_ newTabId: UUID) {
        tabId = newTabId
        attachedView?.tabId = newTabId
        surfaceView.tabId = newTabId
    }

    /// Moves this surface between focus-routing placements and updates the registry.
    @MainActor
    public func setFocusPlacement(_ placement: TerminalSurfaceFocusPlacement) {
        guard focusPlacement != placement else { return }
        focusPlacement = placement
        registry.updateFocusPlacement(id: id, placement)
    }
}
