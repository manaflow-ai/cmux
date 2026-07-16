import AppKit
import CmuxSettings
import CmuxSettingsUI
import CmuxSidebarInterpreterClient
import CmuxSidebarRemoteRender
import CmuxUpdater
import SwiftUI

/// Lightweight provider router for the sidebar.
///
/// The built-in provider uses the native AppKit bridge only while its staged
/// feature flag is enabled. The existing SwiftUI sidebar remains the default
/// and continues to host custom or installed providers.
struct VerticalTabsSidebar: View {
    var updateViewModel: UpdateStateModel
    let fileExplorerState: FileExplorerState
    let windowId: UUID
    let onSendFeedback: () -> Void
    let onToggleSidebar: () -> Void
    let onNewTab: () -> Void
    let observedWindow: NSWindow?
    let tabManager: TabManager
    let sidebarUnread: SidebarUnreadModel
    let cmuxConfigStore: CmuxConfigStore
    @Binding var selection: SidebarSelection
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    @Binding var sidebarRenderWorkerClient: RenderWorkerClient?
    var appKitSidebarEnabledOverride: Bool? = nil
    @AppStorage(CmuxExtensionSidebarSelection.defaultsKey)
    private var selectedExtensionSidebarProviderId = CmuxExtensionSidebarSelection.defaultProviderId
    @LiveSetting(\.betaFeatures.extensions) private var extensionsExperimentalEnabled
    @LiveSetting(\.betaFeatures.customSidebars) private var customSidebarsExperimentalEnabled
    @LiveSetting(\.sidebar.showAgentActivity) private var showAgentActivity
    @LiveSetting(\.shortcuts.showModifierHoldHints) private var showModifierHoldHints
#if DEBUG
    @Environment(\.minimalModeInvalidationProbe) private var minimalModeInvalidationProbe
    @Environment(\.sidebarLazyContractProbe) private var sidebarLazyContractProbe
#endif

    private var effectiveExtensionSidebarProviderId: String {
        let selected = selectedExtensionSidebarProviderId
        if selected.hasPrefix(CmuxExtensionSidebarSelection.customSidebarProviderPrefix) {
            _ = customSidebarsExperimentalEnabled
            return CmuxExtensionSidebarSelection.customSidebarsEnabled
                ? selected
                : CmuxExtensionSidebarSelection.defaultProviderId
        }
        return CmuxExtensionSidebarSelection.effectiveProviderId(
            selected,
            extensionsEnabled: extensionsExperimentalEnabled
        )
    }

    private var workspaceRowInputProjection: (() -> Void)? {
#if DEBUG
        sidebarLazyContractProbe.workspaceRowInputProjection
#else
        nil
#endif
    }

    private var isAppKitSidebarEnabled: Bool {
        appKitSidebarEnabledOverride ?? CmuxFeatureFlags.shared.isAppKitSidebarEnabled
    }

    @ViewBuilder
    var body: some View {
#if DEBUG
        let _ = { minimalModeInvalidationProbe.verticalTabsSidebarBody?() }()
#endif
        if isAppKitSidebarEnabled,
           CmuxExtensionSidebarSelection.resolvesToDefaultSidebar(
            effectiveProviderId: effectiveExtensionSidebarProviderId
        ) {
            SidebarAppKitRuntimeHostRepresentable(
                updateViewModel: updateViewModel,
                fileExplorerState: fileExplorerState,
                windowId: windowId,
                onSendFeedback: onSendFeedback,
                onToggleSidebar: onToggleSidebar,
                onNewTab: onNewTab,
                observedWindow: observedWindow,
                tabManager: tabManager,
                sidebarUnread: sidebarUnread,
                cmuxConfigStore: cmuxConfigStore,
                selection: $selection,
                selectedTabIds: $selectedTabIds,
                lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                showsAgentActivity: showAgentActivity
                    && CmuxFeatureFlags.shared.isSidebarWorkspaceAgentSpinnerEnabled,
                enablesModifierShortcutHints: showModifierHoldHints,
                workspaceRowInputProjection: workspaceRowInputProjection
            )
            .accessibilityIdentifier("Sidebar")
            .ignoresSafeArea()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            LegacyVerticalTabsSidebar(
                updateViewModel: updateViewModel,
                fileExplorerState: fileExplorerState,
                windowId: windowId,
                onSendFeedback: onSendFeedback,
                onToggleSidebar: onToggleSidebar,
                onNewTab: onNewTab,
                observedWindow: observedWindow,
                selection: $selection,
                selectedTabIds: $selectedTabIds,
                lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                sidebarRenderWorkerClient: $sidebarRenderWorkerClient
            )
        }
    }
}
