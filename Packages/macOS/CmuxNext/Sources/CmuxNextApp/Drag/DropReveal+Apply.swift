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
            // `fallback` when it lists the workspace (a guest too: two windows on one space), else the owner window.
            let shows = fallback.flatMap { value.lists(workspaceID, in: $0.state.id) ? $0.state.id : nil } ?? value.owner(of: workspaceID)
            let owner = shows.flatMap { value.window($0)?.isOpen == true ? windows.controller(for: $0) : nil }
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

    /// The window that will show a tab after a move into `workspaceID` (its
    /// owner window when open), else the one showing `tabWorkspace` (the tab's now).
    /// `preferring` (the window of a drop) wins when it lists `workspaceID`: two windows on one space both show it,
    /// and the reveal and the focus of one drop must name the same one.
    func landingWindow(tabWorkspace: String?, workspaceID: String?, preferring: WindowController? = nil) -> WindowController? {
        let value = windows.registry.value
        if let workspaceID, let preferring, value.lists(workspaceID, in: preferring.state.id) { return preferring }
        if let workspaceID, let owner = windows.actingWindow(for: workspaceID), value.window(owner)?.isOpen == true {
            return windows.controller(for: owner)
        }
        return tabWorkspace.flatMap { windows.actingWindow(for: $0) }.flatMap(windows.controller(for:))
    }

    /// The reveal for a move an action started (palette, menu, key, CLI):
    /// only when the run allowed a view change (`ActionRunScope.viewChangeAllowed()`, read
    /// before any await) and the move landed.
    func actionReveal(_ outcome: TabDragOutcome, allowed: Bool, landed: Bool, window: WindowController?,
                      source: WindowController?) -> DropReveal? {
        DropRevealPolicy.decide(.init(outcome: outcome, landed: landed, userInitiated: allowed, crossesWindows: window !== source,
                                      appActive: NSApp.isActive, noActivate: WindowPlacement.noActivate,
                                      landingOnActiveSpace: window?.window?.isOnActiveSpace ?? true))
    }
}
