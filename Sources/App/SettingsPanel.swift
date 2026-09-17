import AppKit
import Bonsplit
import CmuxSettingsUI
import CmuxWorkspaces
import SwiftUI

/// Settings hosted as a pane in a workspace instead of a separate window. The
/// pane mounts the same ``SettingsWindowHostRoot`` the window uses, so section
/// navigation (menu, ⌘,, palette, `cmux settings open`) reaches it through the
/// one `SettingsNavigationRequest` bridge. Never persisted: a restored session
/// reopens Settings on demand, not from a snapshot.
@MainActor
final class SettingsPanel: Panel {
    let id = UUID()
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .settings
    /// Section the pane mounts first when the open that created it was targeted.
    let initialSection: SettingsSectionID?

    var displayTitle: String { String(localized: "settings.title", defaultValue: "Settings") }
    var displayIcon: String? { "gearshape" }

    init(initialSection: SettingsSectionID?) {
        self.initialSection = initialSection
    }

    func focus() {}
    func unfocus() {}
    func close() {}
    func triggerFlash(reason: WorkspaceAttentionFlashReason) { _ = reason }
}

extension Workspace {
    /// The workspace's Settings pane, if one is open.
    var settingsPanel: SettingsPanel? {
        panels.values.compactMap { $0 as? SettingsPanel }.first
    }

    /// Focuses the existing Settings pane or opens one in the focused pane.
    @discardableResult
    func openOrFocusSettingsSurface(initialSection: SettingsSectionID?, focus: Bool = true) -> SettingsPanel? {
        guard !isRetiredFromOwningTabManager else { return nil }
        if let existing = settingsPanel {
            if focus { focusPanel(existing.id) }
            return existing
        }
        guard let paneID = bonsplitController.focusedPaneId ?? bonsplitController.allPaneIds.first else { return nil }
        clearSplitZoom()
        return newSettingsSurface(inPane: paneID, initialSection: initialSection, focus: focus)
    }

    @discardableResult
    func newSettingsSurface(inPane paneID: PaneID, initialSection: SettingsSectionID?, focus: Bool = true) -> SettingsPanel? {
        let panel = SettingsPanel(initialSection: initialSection)
        panels[panel.id] = panel
        panelTitles[panel.id] = panel.displayTitle

        guard let tabID = bonsplitController.createTab(
            title: panel.displayTitle,
            icon: panel.displayIcon,
            kind: SurfaceKind.settings.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneID
        ) else {
            panels.removeValue(forKey: panel.id)
            panelTitles.removeValue(forKey: panel.id)
            return nil
        }

        bindSurface(tabID, toPanelId: panel.id)
        publishCmuxSurfaceCreated(panel.id, paneId: paneID, kind: SurfaceKind.settings.rawValue, origin: "settings_pane", focused: focus)
        if focus {
            bonsplitController.focusPane(paneID)
            bonsplitController.selectTab(tabID)
            applyTabSelection(tabId: tabID, inPane: paneID)
        }
        return panel
    }
}

struct SettingsPanelView: View {
    let panel: SettingsPanel
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    var body: some View {
        SettingsWindowHostRoot(
            initialSection: panel.initialSection,
            onContentAppear: { SettingsWindowPresenter.shared.deliverPendingNavigationAfterContentAppears() },
            presentation: .pane
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: appearance.contentBackgroundColor))
        .simultaneousGesture(TapGesture().onEnded { onRequestPanelFocus() })
        .accessibilityIdentifier("SettingsPanel")
    }
}
