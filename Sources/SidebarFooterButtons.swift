import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxSettings
import CmuxWorkspaces
import CmuxUpdater
import CmuxUpdaterUI
import SwiftUI

struct SidebarFooterButtons: View {
    var updateViewModel: UpdateStateModel
    let fileExplorerState: FileExplorerState
    let modifierKeyMonitor: WindowScopedShortcutHintModifierMonitor
    let onSendFeedback: () -> Void
    @State private var extensionBrowserAnchorView: NSView?
    @LiveSetting(\.betaFeatures.extensions) private var extensionsExperimentalEnabled
    // Reuse the exact Command-hold shortcut-hint signal that drives the per-row
    // shortcut badges (`showModifierHoldHints && modifierKeyMonitor.isModifierPressed`,
    // see `resolvedShowsModifierShortcutHints`). Reading `isModifierPressed`
    // (the monitor is `@Observable`) here localizes the reveal re-render to the
    // footer instead of the whole sidebar body.
    @LiveSetting(\.shortcuts.showModifierHoldHints) private var showModifierHoldHints
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue
    /// Owns the discovery popover so it persists after ⌘ is released.
    @State private var isShortcutPopoverPresented = false

#if DEBUG
    @AppStorage(CloudAnnouncementPreviewStyle.selectionKey)
    private var cloudAnnouncementStyle = CloudAnnouncementPreviewStyle.notificationRow.rawValue
    @AppStorage(CloudAnnouncementPreviewStyle.visibilityKey)
    private var cloudAnnouncementVisible = false

    private var announcementStyle: CloudAnnouncementPreviewStyle {
        CloudAnnouncementPreviewStyle(rawValue: cloudAnnouncementStyle) ?? .notificationRow
    }

    private var helpMidX: CGFloat {
        let accountWidth: CGFloat = shows(.account) && CmuxFeatureFlags.shared.isSidebarAccountButtonEnabled ? 22 : 0
        let mobileWidth: CGFloat = shows(.mobileConnect) && CmuxFeatureFlags.shared.isMobileConnectButtonEnabled ? 22 : 0
        return accountWidth + mobileWidth + SidebarFooterButtonMetrics.buttonSize / 2
    }

    private func openCloudChangelog() {
        guard let url = URL(string: "https://cmux.com/docs/changelog") else { return }
        NSWorkspace.shared.open(url)
        cloudAnnouncementVisible = false
    }
#endif

    private var presentationMode: WorkspacePresentationModeSettings.Mode {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode)
    }

    private func shows(_ control: SidebarFooterControl) -> Bool {
        SidebarFooterPresentationPolicy.isVisible(control, presentationMode: presentationMode)
    }

    var body: some View {
#if DEBUG
        VStack(alignment: .leading, spacing: 6) {
            if cloudAnnouncementVisible, shows(.help), announcementStyle != .updatePill {
                SidebarCloudAnnouncementView(
                    style: announcementStyle,
                    accent: cmuxAccentColor(),
                    helpMidX: helpMidX,
                    onOpen: openCloudChangelog,
                    onDismiss: { cloudAnnouncementVisible = false }
                )
                .padding(.leading, 6)
            }
            footerControls
        }
#else
        footerControls
#endif
    }

    private var footerControls: some View {
        HStack(spacing: 4) {
            if shows(.account) || shows(.mobileConnect) || shows(.help) {
                HStack(spacing: 0) {
                    if shows(.account), CmuxFeatureFlags.shared.isSidebarAccountButtonEnabled {
                        SidebarAccountMenuButton()
                    }
                    if shows(.mobileConnect), CmuxFeatureFlags.shared.isMobileConnectButtonEnabled {
                        SidebarMobileConnectButton()
                    }
                    if shows(.help) {
                        SidebarHelpMenuButton(onSendFeedback: onSendFeedback)
                    }
                }
            }
#if DEBUG
            if cloudAnnouncementVisible, shows(.help), announcementStyle == .updatePill {
                SidebarCloudAnnouncementPill(
                    accent: cmuxAccentColor(),
                    onOpen: openCloudChangelog,
                    onDismiss: { cloudAnnouncementVisible = false }
                )
            }
#endif
            // Command-hold reveal: appears immediately before Upgrade. It stays
            // mounted while its popover is open so releasing ⌘ does not dismiss it.
            if shows(.shortcutDiscovery),
               (showModifierHoldHints && modifierKeyMonitor.isModifierPressed) || isShortcutPopoverPresented {
                ShortcutDiscoveryButton(isPopoverPresented: $isShortcutPopoverPresented)
            }
            if shows(.upgrade) {
                SidebarProBadge()
            }
            // The puzzle button opens the extensions browser; it only shows
            // while the experimental Extensions feature is enabled.
            if shows(.extensions), extensionsExperimentalEnabled {
                Button {
                    _ = AppDelegate.shared?.openSidebarExtensionBrowser(
                        from: extensionBrowserAnchorView,
                        title: String(localized: "sidebar.extensions.browser.title", defaultValue: "Sidebar Extensions")
                    )
                } label: {
                    CmuxSystemSymbolImage(magnified: "puzzlepiece.extension", pointSize: 12, weight: .medium, tint: Color(nsColor: .secondaryLabelColor))
                        .frame(width: 22, height: 22, alignment: .center)
                }
                .buttonStyle(SidebarFooterIconButtonStyle())
                .frame(width: 22, height: 22, alignment: .center)
                .safeHelp(String(localized: "sidebar.extensions.browser.title", defaultValue: "Sidebar Extensions"))
                .accessibilityLabel(String(localized: "sidebar.extensions.browser.title", defaultValue: "Sidebar Extensions"))
                .accessibilityIdentifier("SidebarExtensionMenuButton")
                .background(TitlebarControlAnchorView { extensionBrowserAnchorView = $0 })
            }
            if shows(.update), let updateActionsHost = AppDelegate.shared {
                UpdatePill(model: updateViewModel, accent: cmuxAccentColor(), actions: updateActionsHost)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
