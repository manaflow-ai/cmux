import AppKit
import CmuxNextBridge
import CmuxNextDesign

// Applies a `DropReveal` (the view change after a user's move lands):
// client view state of this app only, after the owner's echo.
extension AppServices {
    /// Reveals `tab`, which landed in workspace `workspaceID` (nil: wherever
    /// the window `fallback` shows it): shows that workspace in its window,
    /// focuses the tab, and makes the window key when `reveal` says so.
    /// Never activates the app or switches Spaces (`WindowActivation`).
    func applyReveal(_ reveal: DropReveal, tab: String?, workspaceID: String?, fallback: WindowController?) {
        var controller = fallback
        if let workspaceID {
            let owner = windows.registry.value.owner(of: workspaceID)
            if reveal.showsWorkspace {
                if let owner, let state = windows.states[owner] {
                    windows.select(workspaceID, in: state)
                } else if let state = fallback?.state {
                    windows.claim(workspaceID: workspaceID, in: state)
                }
            }
            controller = windows.registry.value.owner(of: workspaceID).flatMap(windows.controller(for:)) ?? controller
        }
        guard let controller else { return }
        if reveal.focusesTab, let tab { controller.focus.expect(.tab(tab)) }
        if reveal.makesKey, let window = controller.window { WindowActivation.show(window, .raise) }
    }

    /// The reveal for a move an action started (palette, menu, key, CLI):
    /// only when the run allowed a view change (`viewChangeAllowed`, read
    /// before any await) and the move landed.
    func actionReveal(_ outcome: TabDragOutcome, allowed: Bool, landed: Bool, window: WindowController?) -> DropReveal? {
        DropRevealPolicy.decide(.init(outcome: outcome, landed: landed, userInitiated: allowed, appActive: NSApp.isActive,
                                      noActivate: WindowPlacement.noActivate,
                                      landingOnActiveSpace: window?.window?.isOnActiveSpace ?? true))
    }
}
