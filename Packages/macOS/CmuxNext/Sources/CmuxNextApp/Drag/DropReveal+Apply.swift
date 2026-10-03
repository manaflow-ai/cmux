import AppKit
import CmuxNextBridge
import CmuxNextDesign

// Applies a `DropReveal` (the view change after a user's move lands):
// client view state of this app only, after the owner's echo.
extension AppServices {
    /// Applies the parts of `reveal` that the focus expectation set at the
    /// intent does not: shows the workspace `workspaceID` in the window
    /// that owns it (or files it into `fallback`), and makes that window
    /// key through the window manager. Focus itself lands from the
    /// expectation the drop or action set when the user acted (its
    /// generation keeps a newer user choice), never from here.
    func applyReveal(_ reveal: DropReveal, workspaceID: String?, fallback: WindowController?) {
        var controller = fallback
        if let workspaceID {
            let value = windows.registry.value
            let owner = value.owner(of: workspaceID).flatMap { value.window($0)?.isOpen == true ? windows.controller(for: $0) : nil }
            if reveal.showsWorkspace {
                if let owner {
                    windows.select(workspaceID, in: owner.state)
                } else if let state = fallback?.state {
                    windows.claim(workspaceID: workspaceID, in: state)
                }
            }
            controller = owner ?? controller
        }
        if reveal.makesKey, let controller { windows.bringToFront(controller) }
    }

    /// The window that will show `tab` after a move into `workspaceID` (its
    /// owner window when open), else the window showing the tab now.
    func landingWindow(tab: String, workspaceID: String?) -> WindowController? {
        let value = windows.registry.value
        if let workspaceID, let owner = value.owner(of: workspaceID), value.window(owner)?.isOpen == true {
            return windows.controller(for: owner)
        }
        return self.workspaceID(ofTab: tab).flatMap { value.owner(of: $0) }.flatMap(windows.controller(for:))
    }

    /// The reveal for a move an action started (palette, menu, key, CLI):
    /// only when the run allowed a view change (`ViewChangePolicy.allowed()`, read
    /// before any await) and the move landed.
    func actionReveal(_ outcome: TabDragOutcome, allowed: Bool, landed: Bool, window: WindowController?,
                      source: WindowController?) -> DropReveal? {
        DropRevealPolicy.decide(.init(outcome: outcome, landed: landed, userInitiated: allowed, crossesWindows: window !== source,
                                      appActive: NSApp.isActive, noActivate: WindowPlacement.noActivate,
                                      landingOnActiveSpace: window?.window?.isOnActiveSpace ?? true))
    }
}
