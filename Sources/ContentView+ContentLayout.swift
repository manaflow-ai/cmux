import AppKit
import CmuxSocketControl
import Bonsplit
import Combine
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebarProviderKit
import CmuxExtensionSidebarExamples
import CmuxSettings
import CmuxSettingsUI
import CmuxSidebarRemoteRender
import CmuxSwiftRender
import CmuxSwiftRenderUI
import CmuxUpdater
import CmuxUpdaterUI
import ImageIO
import Observation
import SwiftUI
import ObjectiveC
import UniformTypeIdentifiers
import WebKit


// MARK: - Main content, sidebar panels, right sidebar layout
extension ContentView {
    private var sidebarView: some View {
        VerticalTabsSidebar(
            updateViewModel: updateViewModel,
            fileExplorerState: fileExplorerState,
            windowId: windowId,
            onSendFeedback: presentFeedbackComposer,
            onToggleSidebar: { sidebarState.toggle() },
            onNewTab: {
                AppDelegate.shared?.performNewWorkspaceAction(
                    tabManager: tabManager,
                    debugSource: "titlebar.hiddenNewWorkspace"
                )
            },
            observedWindow: observedWindow,
            selection: $sidebarSelectionState.selection,
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex
        )
        .frame(width: sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func terminalContent(appearance: WindowAppearanceSnapshot) -> some View {
        let mountedWorkspaceIdSet = Set(mountedWorkspaceIds)
        let mountedWorkspaces = tabManager.tabs.filter { mountedWorkspaceIdSet.contains($0.id) }
        let selectedWorkspaceId = tabManager.selectedTabId
        let retiringWorkspaceId = self.retiringWorkspaceId

        return ZStack {
            ZStack {
                ForEach(mountedWorkspaces) { tab in
                    let isSelectedWorkspace = selectedWorkspaceId == tab.id
                    let isRetiringWorkspace = retiringWorkspaceId == tab.id
                    let presentation = MountedWorkspacePresentationPolicy.resolve(
                        isSelectedWorkspace: isSelectedWorkspace,
                        isRetiringWorkspace: isRetiringWorkspace
                    )
                    // Keep the retiring workspace visible during handoff, but never input-active.
                    // Allowing both selected+retiring workspaces to be input-active lets the
                    // old workspace steal first responder (notably with WKWebView), which can
                    // delay handoff completion and make browser returns feel laggy.
                    let isInputActive = isSelectedWorkspace
                    let portalPriority = isSelectedWorkspace ? 2 : (isRetiringWorkspace ? 1 : 0)
                    WorkspaceContentView(
                        workspace: tab,
                        isWorkspaceVisible: presentation.isPanelVisible,
                        isWorkspaceInputActive: isInputActive,
                        isFullScreen: isFullScreen,
                        workspacePortalPriority: portalPriority,
                        onThemeRefreshRequest: { reason, eventId, source, payloadHex in
                            scheduleTitlebarThemeRefreshFromWorkspace(
                                workspaceId: tab.id,
                                reason: reason,
                                backgroundEventId: eventId,
                                backgroundSource: source,
                                notificationPayloadHex: payloadHex
                            )
                        }
                    )
                    .opacity(presentation.renderOpacity)
                    .allowsHitTesting(isSelectedWorkspace)
                    .accessibilityHidden(!presentation.isRenderedVisible)
                    .zIndex(isSelectedWorkspace ? 2 : (isRetiringWorkspace ? 1 : 0))
                }
            }
            .opacity(sidebarSelectionState.selection == .tabs ? 1 : 0)
            .allowsHitTesting(sidebarSelectionState.selection == .tabs)
            .accessibilityHidden(sidebarSelectionState.selection != .tabs)

            NotificationsPage(selection: $sidebarSelectionState.selection)
                .opacity(sidebarSelectionState.selection == .notifications ? 1 : 0)
                .allowsHitTesting(sidebarSelectionState.selection == .notifications)
                .accessibilityHidden(sidebarSelectionState.selection != .notifications)
        }
        .padding(.top, effectiveTitlebarPadding)
    }

    private func terminalContentWithSidebarDropOverlay(appearance: WindowAppearanceSnapshot) -> some View {
        terminalContent(appearance: appearance)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            .overlay {
                SidebarExternalDropOverlay(draggedTabId: sidebarDraggedTabId)
            }
    }

    private func terminalContentWithRightSidebarPanel(appearance: WindowAppearanceSnapshot) -> some View {
        // File explorer is always in the view tree. Visibility is controlled by
        // frame width (0 when hidden), avoiding SwiftUI view insertion/removal
        // and all associated transition animations.
        return HStack(spacing: 0) {
            terminalContentWithSidebarDropOverlay(appearance: appearance)
            rightSidebarPanelWithBackdrop(appearance: appearance)
        }
    }

    var rightSidebarVisible: Bool {
        fileExplorerState.isVisible
    }

    var rightSidebarWidth: CGFloat {
        rightSidebarVisible ? fileExplorerWidth : 0
    }

    private func sidebarBackdropLayer(
        width: CGFloat,
        role: WindowBackdropRole,
        appearance: WindowAppearanceSnapshot
    ) -> some View {
        WindowBackdropLayer(role: role, snapshot: appearance)
            .ignoresSafeArea()
            .frame(width: width)
            .clipShape(RoundedRectangle(cornerRadius: appearance.sidebarSettings.materialPolicy.cornerRadius, style: .continuous))
            .clipped()
            .allowsHitTesting(false)
    }

    private func sidebarPanelContainer<Content: View>(
        width: CGFloat,
        alignment: Alignment,
        role: WindowBackdropRole,
        appearance: WindowAppearanceSnapshot,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack(alignment: alignment) {
            sidebarBackdropLayer(width: width, role: role, appearance: appearance)
            content()
                .environment(\.colorScheme, appearance.sidebarContentColorScheme)
        }
        .frame(width: width)
    }

    private func sidebarPanelWithBackdrop(appearance: WindowAppearanceSnapshot) -> some View {
        sidebarPanelContainer(width: sidebarWidth, alignment: .leading, role: .leftSidebar, appearance: appearance) {
            sidebarView
        }
    }

    private func rightSidebarPanelWithBackdrop(appearance: WindowAppearanceSnapshot) -> some View {
        let panel = sidebarPanelContainer(width: rightSidebarWidth, alignment: .trailing, role: .rightSidebar, appearance: appearance) {
            rightSidebarPanel
        }
        .overlay(alignment: .leading) {
            if rightSidebarVisible {
                WindowChromeBorder(orientation: .vertical)
            }
        }

        return panel
    }

    private var rightSidebarPanel: some View {
        return RightSidebarPanelView(
            tabManager: tabManager,
            fileExplorerStore: fileExplorerStore,
            fileExplorerState: fileExplorerState,
            sessionIndexStore: sessionIndexStore,
            titlebarHeight: RightSidebarChromeMetrics.titlebarHeight,
            workspaceId: tabManager.selectedTabId,
            onResumeSession: { entry in
                resumeSession(entry: entry)
            },
            onOpenFilePreview: { filePath in
                openFilePreviewFromSidebar(filePath: filePath)
            },
            onOpenAsPane: { mode in
                openRightSidebarToolPane(mode)
            },
            onClose: {
                #if DEBUG
                cmuxDebugLog("rightSidebar.closeButton")
                #endif
                _ = AppDelegate.shared?.closeRightSidebarInActiveMainWindow(preferredWindow: observedWindow)
            }
        )
        .frame(width: rightSidebarWidth)
        .clipped()
        .allowsHitTesting(rightSidebarVisible)
        .accessibilityHidden(!rightSidebarVisible)
        .transaction { $0.animation = nil }
        .onAppear {
            let sanitized = normalizedRightSidebarWidth(fileExplorerState.width)
            fileExplorerWidth = sanitized
            if abs(fileExplorerState.width - sanitized) > 0.5 {
                DispatchQueue.main.async {
                    fileExplorerState.width = sanitized
                }
            }
        }
        .onChange(of: fileExplorerState.width) { newValue in
            if fileExplorerDragStartWidth == nil {
                let sanitized = normalizedRightSidebarWidth(newValue)
                if abs(newValue - sanitized) > 0.5 {
                    DispatchQueue.main.async {
                        fileExplorerState.width = sanitized
                    }
                    return
                }
                fileExplorerWidth = sanitized
            }
        }
    }

    func contentAndSidebarLayout(appearance: WindowAppearanceSnapshot) -> AnyView {
        let layout: AnyView
        // When matching terminal background, use HStack so both sidebar and terminal
        // sit directly on the window background with no intermediate layers.
        let useWithinWindow = sidebarBlendMode == SidebarBlendModeOption.withinWindow.rawValue
            && !sidebarMatchTerminalBackground
        if useWithinWindow {
            // Overlay mode keeps the left sidebar on top, but the right
            // sidebar stays in an HStack so terminal rows are clipped before
            // the sidebar backdrop samples the window.
            layout = AnyView(
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        terminalContentWithSidebarDropOverlay(appearance: appearance)
                            .padding(.leading, sidebarState.isVisible ? sidebarWidth : 0)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .layoutPriority(1)
                        rightSidebarPanelWithBackdrop(appearance: appearance)
                    }
                    if sidebarState.isVisible {
                        sidebarPanelWithBackdrop(appearance: appearance)
                    }
                }
            )
        } else {
            // Standard HStack mode for behindWindow blur
            layout = AnyView(
                HStack(spacing: 0) {
                    if sidebarState.isVisible {
                        sidebarPanelWithBackdrop(appearance: appearance)
                    }
                    terminalContentWithRightSidebarPanel(appearance: appearance)
                }
            )
        }

        return AnyView(
            layout
                .overlay(alignment: .leading) {
                    if sidebarState.isVisible {
                        sidebarResizerOverlay
                            .zIndex(1000)
                    }
                }
                .overlay(alignment: .leading) {
                    if rightSidebarVisible {
                        rightSidebarResizerOverlay
                            .zIndex(1000)
                    }
                }
        )
    }

}
