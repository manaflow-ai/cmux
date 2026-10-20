import CmuxNextActions
import CmuxNextDesign
import Foundation

/// Each pane's own background and marker tint (plans/cmux-next/pane-backgrounds-DESIGN.md). Kept
/// app-locally by the pane's durable resource id (`<session>/<pane_…>`), so a pane keeps its look
/// when it moves to another window or workspace and across relaunches; a split's new pane has
/// none and follows its workspace.
extension ThemeCoordinator {
    /// The store key of a pane, or nil for a pane without a durable id (an old daemon).
    func paneBackgroundKey(_ pane: PaneController) -> String? {
        guard let session = pane.daemon.store.registryID, let resource = pane.pane.resourceID?.rawValue else { return nil }
        return WorkspaceBackgroundStore.key(session: session, workspace: resource)
    }

    /// A pane's own background value (`appearance.background`'s vocabulary), nil when it inherits.
    func paneBackground(_ pane: PaneController) -> String? {
        paneBackgroundKey(pane).flatMap(paneBackgrounds.background(for:))
    }

    /// A pane's marker tint, nil without one.
    func paneTint(_ pane: PaneController) -> PaneTint? {
        paneBackgroundKey(pane).flatMap(paneTints.background(for:)).flatMap(PaneTint.init)
    }

    /// Gives `pane` its own background and tint, as saved.
    func applyPaneBackground(_ pane: PaneController) {
        pane.view.setPaneBackground(pin: WorkspaceBackgroundStore.pin(paneBackground(pane), now: Date()), tint: paneTint(pane))
    }

    /// Re-applies every mounted pane of every window (a store or day change).
    func applyPaneBackgrounds() {
        for controller in services.windows.controllers {
            for content in controller.mountedContents { for pane in content.panes.values { applyPaneBackground(pane) } }
        }
    }

    /// Saves a pane's own background (`inherit` or nil follows its workspace again).
    ///
    /// - Returns: False when the pane has no durable id to save it under.
    @discardableResult
    func setPaneBackground(_ value: String?, for pane: PaneController) -> Bool {
        guard let key = paneBackgroundKey(pane) else { return false }
        paneBackgrounds.set(value == "inherit" ? nil : value, for: key)
        applyPaneBackground(pane)
        return true
    }

    /// Saves a pane's marker tint (nil clears it).
    ///
    /// - Returns: False when the pane has no durable id to save it under.
    @discardableResult
    func setPaneTint(_ tint: PaneTint?, for pane: PaneController) -> Bool {
        guard let key = paneBackgroundKey(pane) else { return false }
        paneTints.set(tint?.id, for: key)
        applyPaneBackground(pane)
        return true
    }

    /// The pane a choice menu or picker shows its check for: the target pane, else the focused one.
    /// Never refuses (a menu's state query must not post a refusal).
    func paneForChoice(_ target: ActionTargetRef?) -> PaneController? {
        guard let target, target.kind == .pane else { return services.windows.active?.focusedPane }
        for controller in services.windows.controllers {
            for content in controller.mountedContents {
                if let pane = content.panes.values.first(where: { $0.paneKey == target.id }) { return pane }
            }
        }
        return nil
    }
}
