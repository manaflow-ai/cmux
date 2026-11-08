import AppKit
import Foundation
import Observation

/// Lightweight browser surface used while a session restore is assembling its topology.
///
/// A deferred panel keeps the persisted browser metadata and tab identity, but does not
/// construct a ``WKWebView`` until the pane is actually visible. This is intentionally a
/// ``Panel`` rather than a Bonsplit-only placeholder so the restored layout remains fully
/// navigable (and serializable) while WebKit work is kept out of the launch burst.
@MainActor
@Observable
final class DeferredBrowserPanel: Panel {
    let id: UUID
    private(set) var workspaceId: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .browser

    /// The complete persisted panel record used to materialize the real browser later.
    let sessionPanelSnapshot: SessionPanelSnapshot

    var displayTitle: String {
        sessionPanelSnapshot.customTitle
            ?? sessionPanelSnapshot.title
            ?? sessionPanelSnapshot.browser?.urlString
            ?? String(localized: "browser.newTab", defaultValue: "New tab")
    }

    var displayIcon: String? { "globe" }

    init(
        id: UUID,
        workspaceId: UUID,
        snapshot: SessionPanelSnapshot
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.sessionPanelSnapshot = snapshot
    }

    /// Updates the owning workspace after a cross-workspace panel transfer.
    func updateWorkspaceId(_ workspaceId: UUID) {
        self.workspaceId = workspaceId
    }

    func close() {
        // The owning Workspace or DockSplitStore removes the placeholder from its registry.
        // There are no native resources to release before that removal.
    }

    // Materialization is owned by Workspace or DockSplitStore; a placeholder
    // must not mutate its registry from a generic Panel focus callback.
    func focus() {}
    func unfocus() {}
    func triggerFlash(reason: WorkspaceAttentionFlashReason) {}

    deinit {}
}
