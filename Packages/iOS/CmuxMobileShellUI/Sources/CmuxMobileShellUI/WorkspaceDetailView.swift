import CMUXMobileCore
import CmuxAgentChat
import CmuxAgentChatUI
import CmuxMobileBrowser
import CmuxMobileBrowserStream
import CmuxMobileDiagnostics
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileTerminal
import CmuxMobileToast
import CmuxMobileWorkspace
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

struct WorkspaceDetailView: View {
    static func reconnectAction(
        connectionRequiresReauth: Bool,
        reconnect: @escaping () -> Void
    ) -> (() -> Void)? {
        connectionRequiresReauth ? nil : reconnect
    }

    let host: String
    let connectionStatus: MobileMacConnectionStatus
    let workspace: MobileWorkspacePreview
    @Bindable var store: CMUXMobileShellStore
    let createWorkspace: () -> Void
    let canCreateWorkspace: Bool
    let createTerminal: () -> Void
    let renameWorkspace: ((MobileWorkspacePreview.ID, String) -> Void)?
    let customizeWorkspace: WorkspaceCustomizationAction?
    let setWorkspaceUnread: ((MobileWorkspacePreview.ID, Bool) -> Void)?
    /// Close this workspace on the Mac. When `nil`, the close affordance is
    /// hidden from the top-bar menu, matching the workspace list's gating.
    let closeWorkspace: ((MobileWorkspacePreview.ID) -> Void)?
    let reportTerminalViewport: (MobileWorkspacePreview.ID, MobileTerminalPreview.ID, MobileTerminalViewportSize) -> Void
    let sendTerminalInput: (String) -> Void
    let safeAreaContext: MobileTerminalSafeAreaContext
    /// How the pane-zoom pair may be hosted here: `.navigationPush` when this
    /// view is a pushed destination of an ancestor `NavigationStack` (where a
    /// nested stack would trap the shared `NavigationAuthority`), `.column`
    /// when it owns its navigation column (split detail, standalone hosts).
    let paneZoomHosting: PaneZoomHosting
    let backButtonConfiguration: WorkspaceBackButtonConfiguration?
    let signOut: (@MainActor @Sendable () -> Void)?
    @Environment(BrowserSurfaceStore.self) var browserStore
    @Environment(BrowserStreamStore.self) var browserStreamStore
    @Environment(MobileDisplaySettings.self) private var displaySettings
    @Environment(ToastCenter.self) private var toasts
    /// Drives the destructive close-workspace confirmation dialog.
    @State var isConfirmingClose = false
    #if canImport(UIKit)
    @State private var isFeedbackComposerPresented = false
    @State private var feedbackText = ""
    @State private var feedbackEmail = ""
    @State private var isSubmittingFeedback = false
    @State private var feedbackErrorMessage: String?
    @State private var isTextSheetPresented = false
    /// Drives the rename-workspace dialog launched from the title menu, and its
    /// editable text (seeded with the current name when presented).
    @State var isRenamePresented = false
    @State var renameText = ""
    /// Drives the shared workspace identity editor from the title menu.
    @State var isCustomizationPresented = false
    /// Live pane width for capping the leading glass title pill.
    @State private var contentWidth: CGFloat = 0
    /// Terminal captured for the current "View as Text" sheet presentation.
    @State private var textSheetSurfaceID: String?
    @Namespace private var paneZoomNamespace
    @State private var paneZoomPresentation = PaneZoomPresentationState()
    @State private var paneMapRefreshTrigger = 0
    @State private var isPaneMapRefreshing = false
    /// Chat-mode toggle for inline agent chat in place of the terminal.
    @State var isChatMode = false
    /// The session chat mode was entered on, pinned so sorting cannot swap the conversation
    /// out from under the user mid-read. Cleared when chat mode turns off.
    @State var pinnedChatSessionID: String?
    @State var chatSessions: [ChatSessionDescriptor] = []
    @State var chatSessionsWorkspaceID: String?
    /// Last terminal id whose cached snapshot said it had a chat session.
    @State var cachedChatToggleTerminalID: String?
    @State var ignoredChatSessionRefreshKey: String?
    @State var ignoredChatSessionRefreshID: UUID?
    @State var ignoredChatSessionRefreshTask: Task<[ChatSessionDescriptor]?, Never>?
    /// Per-session chat stores kept warm while the workspace detail is visible.
    @State var chatConversationStores: [String: ChatConversationStore] = [:]
    /// Per-session composer drafts, surviving toggles back to the terminal.
    @State var chatDrafts: [String: String] = [:]
    @State var terminalArtifactFilesContext: TerminalArtifactContext?
    @State var selectedTerminalArtifact: TerminalArtifactSelection?
    @State var terminalArtifactThumbnailCache = ChatArtifactThumbnailCache()
    @State var visibleArtifactCount = 0
    /// Shared presentation state for the toolbar, title-menu, and hint entry points.
    @State var isWorkspaceChangesSheetPresented = false
    @State var workspaceChangesHint: MobileWorkspaceChangesHint?
    @State var artifactGalleryRefreshSignal = TerminalArtifactGalleryRefreshSignal.initial
    /// App lifecycle phase used to re-pull chat sessions on foreground.
    @Environment(\.scenePhase) var scenePhase
    #endif
    /// The active browser surface for this workspace, when a browser pane is open.
    var activeBrowser: BrowserSurfaceState? {
        browserStore.activeBrowser(for: workspace.id.rawValue)
    }
    var activeBrowserStream: BrowserStreamSurfaceState? {
        browserStreamStore.activeState(in: workspace.rpcWorkspaceID.rawValue)
    }
    #if os(iOS)
    var terminalFilesChipEnabled: Bool {
        displaySettings.terminalFilesChipEnabled
    }
    var showMissingFiles: Bool {
        displaySettings.showMissingFiles
    }
    var terminalFolderTapEnabled: Bool {
        displaySettings.terminalFolderTapEnabled
    }
    var activeSurface: WorkspaceActiveSurface {
        WorkspaceActiveSurface.derive(
            isChatMode: isChatMode,
            hasChosenChatSession: chosenChatSession != nil,
            hasActiveBrowser: activeBrowser != nil,
            hasActiveBrowserStream: activeBrowserStream != nil
        )
    }
    #endif
    var body: some View {
        #if os(iOS)
        // The presentation set is attached twice with opposite gates: once
        // here (live whenever the base layer is what the user sees) and once
        // inside the terminal's full-screen cover in push hosting (live while
        // the cover is up), because a covered base cannot present sheets or
        // dialogs. Exactly one attachment is active at a time.
        detailPresentations(
            detailRootContent,
            active: !terminalCoverIsPresented
        )
        #else
        Group { detailSurfaceContent }
            .closeWorkspaceConfirmation(
                isPresented: $isConfirmingClose,
                confirm: confirmCloseWorkspaceFromMenu
            )
            .mobileConnectionRecoveryOverlay(store: store, signOut: signOut)
        #endif
    }

    #if os(iOS)
    private var detailRootContent: some View {
        Group {
            if let layout = workspace.layout {
                PaneZoomHost(
                    presentation: $paneZoomPresentation,
                    hosting: paneZoomHosting,
                    terminalTheme: store.activeTerminalTheme,
                    zoomSourceID: paneZoomSourceSurfaceID,
                    zoomNamespace: paneZoomNamespace
                ) {
                    paneMapRoot(layout: layout)
                        .accessibilityHidden(paneZoomPresentation.isTerminalPresented)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
                        .navigationTitle(systemNavigationTitle)
                        .mobileTerminalNavigationChrome(theme: store.activeTerminalTheme)
                        .toolbar { workspaceDetailToolbar(mode: .paneMap) }
                        .navigationBarBackButtonHidden(true)
                } terminal: {
                    detailPresentations(
                        terminalWorkspaceEndpoint
                            .mobileSurfaceDeckInset(
                                isVisible: shouldShowSurfaceDeck,
                                value: surfaceDeckValue,
                                actions: surfaceDeckActions,
                                terminalTheme: store.activeTerminalTheme
                            )
                            .navigationBarBackButtonHidden(true),
                        active: terminalCoverIsPresented
                    )
                }
            } else {
                terminalWorkspaceEndpoint
                    .mobileSurfaceDeckInset(
                        isVisible: shouldShowSurfaceDeck,
                        value: surfaceDeckValue,
                        actions: surfaceDeckActions,
                        terminalTheme: store.activeTerminalTheme
                    )
            }
        }
        .background {
            store.activeTerminalTheme.terminalBackgroundColor
                .ignoresSafeArea()
        }
        .onChange(of: workspace.layout != nil) { _, hasLayout in
            paneZoomPresentation.layoutAvailabilityDidChange(hasLayout: hasLayout)
        }
    }

    /// Whether the terminal currently renders inside a full-screen cover
    /// (push hosting only), which blocks presentations from the covered base.
    private var terminalCoverIsPresented: Bool {
        paneZoomHosting == .navigationPush
            && workspace.layout != nil
            && paneZoomPresentation.isTerminalPresented
    }

    /// The workspace detail's sheets, dialogs, and the connection-recovery
    /// overlay. Attached to both the base layer and the terminal cover with
    /// opposite `active` gates so state stays shared while only the visible
    /// layer presents. Gating happens through the bindings (not structurally)
    /// so flipping layers never changes subtree identity.
    private func detailPresentations(
        _ content: some View,
        active: Bool
    ) -> some View {
        content
            .closeWorkspaceConfirmation(
                isPresented: presentationGate($isConfirmingClose, active: active),
                confirm: confirmCloseWorkspaceFromMenu
            )
            .sheet(isPresented: presentationGate($isFeedbackComposerPresented, active: active)) {
                feedbackComposer
            }
            .sheet(isPresented: presentationGate($isTextSheetPresented, active: active)) {
                TerminalTextSheetView(surfaceID: textSheetSurfaceID)
            }
            .sheet(isPresented: presentationGate($isWorkspaceChangesSheetPresented, active: active)) {
                WorkspaceChangesSheet(
                    store: store,
                    workspaceID: workspace.rpcWorkspaceID.rawValue,
                    workspaceTitle: workspace.name
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .workspaceRenameDialog(
                isPresented: presentationGate($isRenamePresented, active: active),
                text: $renameText,
                onSave: commitRenameFromDialog
            )
            .sheet(isPresented: presentationGate($isCustomizationPresented, active: active)) {
                WorkspaceCustomizationSheet(workspace: workspace) { initialDraft, submittedDraft in
                    await customizeWorkspace?(workspace.id, initialDraft, submittedDraft)
                        ?? .failure()
                }
            }
            .mobileConnectionRecoveryOverlay(
                store: store,
                signOut: signOut,
                isActive: active
            )
    }

    /// A presentation binding that reads as presented only while its layer is
    /// the visible one. Writes always land in the shared state, so a dismiss
    /// from either layer clears the flag.
    private func presentationGate(
        _ binding: Binding<Bool>,
        active: Bool
    ) -> Binding<Bool> {
        Binding(
            get: { active && binding.wrappedValue },
            set: { binding.wrappedValue = $0 }
        )
    }

    private var shouldShowSurfaceDeck: Bool {
        // The deck is the workspace's surface picker, including the documented
        // exit path from a browser stream (BrowserStreamPane has no close
        // affordance of its own). Hiding it during a stream would strand
        // no-layout workspaces on the stream with no way back to a terminal.
        (activeSurface == .terminal || activeSurface == .browserStream)
            && paneZoomPresentation.isTerminalPresented
            && surfaceDeckValue.shouldShow
    }

    private var terminalWorkspaceEndpoint: some View {
        let content = Group { detailSurfaceContent }

        return content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
            .navigationTitle(systemNavigationTitle)
            .mobileTerminalNavigationChrome(theme: store.activeTerminalTheme)
            .toolbar { workspaceDetailToolbar(mode: .terminal) }
            .task(id: chatRefreshKey) { await refreshChatSessions() }
            .task(id: workspace.rpcWorkspaceID.rawValue) {
                await store.refreshMobileBrowserPanels(workspaceID: workspace.rpcWorkspaceID.rawValue)
            }
            .task(id: chatConversationWarmKey) { await runWarmChatConversation() }
            .onAppear { refreshWorkspaceChangesHint() }
            .onChange(of: workspaceChangesHintEligibilityKey) { _, _ in
                refreshWorkspaceChangesHint()
            }
            .onChange(of: selectedTerminalID) { _, _ in
                visibleArtifactCount = 0
                refreshCachedChatToggleAnchor()
            }
            .onChange(of: store.supportsTerminalArtifacts) { _, supportsArtifacts in
                visibleArtifactCount = 0
            }
            .onChange(of: store.supportsChatArtifactGallery) { _, _ in
                visibleArtifactCount = 0
            }
    }

    private func paneMapRoot(layout: MobilePaneLayout) -> some View {
        PaneMapOverlay(
            value: PaneMapValue(
                layout: layout,
                phoneSelectedSurfaceID: selectedTerminal?.id.rawValue,
                agentStateKindsBySurfaceID: surfaceDeckAgentStateKinds
            ),
            terminalTheme: store.activeTerminalTheme,
            zoomNamespace: paneZoomNamespace,
            isVisible: !paneZoomPresentation.isTerminalPresented,
            allowsReordering: workspace.actionCapabilities.supportsPaneReorder,
            refreshTrigger: paneMapRefreshTrigger,
            fetchPreviews: { selectedSurfaceIDs, remainingSurfaceIDs in
                await store.fetchPaneMapPreviewGrids(
                    remoteWorkspaceID: workspace.rpcWorkspaceID.rawValue,
                    selectedSurfaceIDs: selectedSurfaceIDs,
                    remainingSurfaceIDs: remainingSurfaceIDs
                )
            },
            selectTerminal: presentTerminalFromPaneMap,
            reorderPanes: reorderPanesFromMap,
            refreshingChanged: { isPaneMapRefreshing = $0 }
        )
    }

    private var paneZoomSourceSurfaceID: String {
        paneZoomPresentation.sourceSurfaceID
            ?? selectedTerminal?.id.rawValue
            ?? workspace.layout?.orderedPanes
                .compactMap(\.selectedSurfaceID)
                .first
            ?? ""
    }

    private enum WorkspaceDetailToolbarMode {
        case paneMap
        case terminal
    }

    @ToolbarContentBuilder
    private func workspaceDetailToolbar(
        mode: WorkspaceDetailToolbarMode
    ) -> some ToolbarContent {
        // In push hosting the pane-map bar stays mounted (covered) while the
        // terminal's full-screen cover shows its own bar with the same shared
        // items. Without this gate both back buttons and title menus exist in
        // the accessibility tree at once, breaking assistive tech and any
        // identifier-based automation with "multiple matching elements".
        let coveredByTerminal = mode == .paneMap && terminalCoverIsPresented
        if backButtonConfiguration != nil {
            ToolbarItem(id: "workspace-back", placement: .topBarLeading) {
                workspaceBackToolbarButton
                    .accessibilityHidden(coveredByTerminal)
            }
            if #available(iOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .topBarLeading)
            }
        }
        ToolbarItem(id: "workspace-title", placement: .topBarLeading) {
            workspaceTitleToolbarMenu(mode: mode)
                .accessibilityHidden(coveredByTerminal)
        }
        if workspaceChangesAreAvailable {
            ToolbarItem(id: "workspace-changes", placement: .topBarTrailing) {
                WorkspaceChangesToolbarButton(
                    chip: workspaceChangesChip,
                    workspaceID: workspace.rpcWorkspaceID.rawValue,
                    action: openWorkspaceChanges
                )
                // The chrome sits on the terminal theme's background, not the
                // system scheme; resolve the counts' green/red for that.
                .environment(\.colorScheme, store.activeTerminalTheme.terminalColorScheme)
                .accessibilityHidden(coveredByTerminal)
            }
        }
        switch mode {
        case .terminal:
            ToolbarItem(id: "workspace-trailing", placement: .topBarTrailing) {
                workspaceToolbarTrailingContent
            }
        case .paneMap:
            ToolbarItem(id: "pane-map-refresh", placement: .topBarTrailing) {
                PaneMapRefreshToolbarButton(
                    isRefreshing: isPaneMapRefreshing,
                    refresh: refreshPaneMapFromToolbar
                )
                .accessibilityHidden(coveredByTerminal)
            }
            ToolbarItem(id: "workspace-trailing", placement: .topBarTrailing) {
                PaneMapDoneToolbarButton(done: returnToTerminalFromPaneMap)
                    .accessibilityHidden(coveredByTerminal)
            }
        }
    }

    private func workspaceTitleToolbarMenu(
        mode: WorkspaceDetailToolbarMode
    ) -> some View {
        let value = WorkspaceTitleMenuValue(
            contentWidth: contentWidth,
            hasBackButton: backButtonConfiguration != nil,
            hasTrailingCluster: true,
            // Reserve the same leading-title geometry in both endpoints even
            // though the chat control itself only appears in terminal mode.
            hasChatToggle: shouldShowChatToggle,
            reservesPaneMapControls: workspace.layout != nil,
            isEnabled: hasTitleMenuActions,
            workspaceName: workspace.name,
            hasUnread: workspace.hasUnread,
            canCustomizeWorkspace: customizeWorkspace != nil,
            canRenameWorkspace: renameWorkspace != nil,
            canToggleReadState: setWorkspaceUnread != nil,
            canCloseWorkspace: closeWorkspace != nil,
            labelToken: toolbarTitleLabelToken(mode: mode),
            terminalTheme: store.activeTerminalTheme
        )
        return WorkspaceTitleMenu(
            value: value,
            menuContent: {
                WorkspaceTitleMenuContent(
                    workspaceName: value.workspaceName,
                    hasUnread: value.hasUnread,
                    canCustomizeWorkspace: value.canCustomizeWorkspace,
                    canRenameWorkspace: value.canRenameWorkspace,
                    canToggleReadState: value.canToggleReadState,
                    canCloseWorkspace: value.canCloseWorkspace,
                    presentCustomization: presentCustomizationFromMenu,
                    presentRename: presentRenameFromMenu,
                    toggleReadState: toggleWorkspaceReadStateFromMenu,
                    requestClose: requestCloseWorkspaceFromMenu
                )
            },
            label: {
                switch value.labelToken {
                case .chat(
                    let descriptor,
                    let agentState,
                    let isConnected,
                    let titleOverride,
                    let subtitle
                ):
                    ChatSessionHeaderView(
                        descriptor: descriptor,
                        agentState: agentState,
                        isConnected: isConnected,
                        titleOverride: titleOverride,
                        subtitle: subtitle,
                        style: .toolbarCompact
                    )
                case .browser(let title):
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(value.terminalTheme.terminalChromeForegroundColor)
                case .standard(let title, let subtitle):
                    WorkspaceToolbarTitleView(title: title, subtitle: subtitle)
                }
            }
        )
        .equatable()
    }

    private func toolbarTitleLabelToken(
        mode: WorkspaceDetailToolbarMode
    ) -> WorkspaceTitleMenuLabelToken {
        if mode == .paneMap,
           let layout = workspace.layout {
            let paneMapValue = PaneMapValue(
                layout: layout,
                phoneSelectedSurfaceID: selectedTerminal?.id.rawValue,
                agentStateKindsBySurfaceID: surfaceDeckAgentStateKinds
            )
            return .standard(
                title: workspace.name,
                subtitle: paneMapValue.countSubtitle
            )
        } else if isChatMode,
           let session = chosenChatSession,
           let conversation = chatConversationStores[session.id] {
            return .chat(
                descriptor: conversation.descriptor,
                agentState: conversation.agentState,
                isConnected: conversation.isConnected,
                titleOverride: workspace.name,
                subtitle: tabName(for: session)
            )
        } else if let browser = activeBrowser {
            return .browser(title: browser.title ?? workspace.name)
        } else if let browser = activeBrowserStream {
            return .browser(title: browser.title ?? workspace.name)
        } else {
            return .standard(title: workspace.name, subtitle: selectedToolbarSubtitle)
        }
    }

    @ViewBuilder
    private var workspaceToolbarTrailingContent: some View {
        HStack(spacing: 8) {
            if let selectedTerminalID,
               store.isAlternateScreen(surfaceID: selectedTerminalID),
               displaySettings.showAltScreenNotice {
                AltScreenNoticeButton {
                    displaySettings.showAltScreenNotice = false
                }
                .frame(width: 44, height: 44)
            }
            toolbarTrailingCluster
        }
    }
    #endif

    func detailContent() -> some View {
        // `GhosttySurfaceView` owns the bottom accessory bar and reserves its
        // height in the terminal grid.
        Group {
            #if os(iOS)
            if let terminalID = selectedTerminal?.id.rawValue {
                terminalArtifactSurface(terminalID: terminalID)
            } else {
                store.activeTerminalTheme.terminalBackgroundColor
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            #else
            store.activeTerminalTheme.terminalBackgroundColor
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            #endif
        }
        // The disconnected terminal stays visible; block interaction so
        // keystrokes aren't silently dropped by the disconnected drain path.
        // The status pill attaches after this modifier and stays tappable.
        .allowsHitTesting(!terminalInputIsBlocked)
        #if os(iOS)
        // Hit-testing only blocks new touches: a terminal focused before the
        // drop (or autofocused on window attach) keeps its keyboard, and its
        // keystrokes drain into the disconnected path silently. Release the
        // input proxy on mount, on status changes, and on flag flips.
        .onChange(of: terminalInputIsBlocked, initial: true) { _, isBlocked in
            resignTerminalInputIfBlocked(isBlocked)
        }
        .onChange(of: store.selectedWorkspaceID) { _, _ in
            // A retained detail can go unavailable while hidden (the
            // selection guard skips it); when it becomes selected again the
            // blocked predicate may not change, so re-check on selection.
            resignTerminalInputIfBlocked(terminalInputIsBlocked)
        }
        #endif
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            // The terminal's only connection chrome: last-known content stays
            // visible and scrollable underneath while the pill shows the
            // reconnect progress (or offers Reconnect once attempts stop).
            MobileMacConnectionStatusPill(
                host: host,
                status: effectiveConnectionStatus,
                reconnect: Self.reconnectAction(
                    connectionRequiresReauth: store.connectionRequiresReauth,
                    reconnect: { reconnectToWorkspaceMac() }
                )
            )
                .padding(.top, 10)
                .padding(.leading, 10)
        }
        #if os(iOS) && DEBUG
        // DEBUG/UI-test-only store-side composer probe.
        .overlay {
            ComposerStoreProbe(
                isComposerPresented: store.isComposerPresented,
                composerFocusRequest: store.composerFocusRequest,
                draftLength: store.terminalInputText.count
            )
        }
        #endif
        #if os(iOS)
        // The whole bottom dock is owned by `GhosttySurfaceView` in one
        // coordinate system, so composer growth pushes only the terminal up.
        .mobileTerminalSafeAreaExpansion(
            context: safeAreaContext,
            includesBottom: true
        )
        .background {
            // Fill under translucent chrome with the terminal's own color.
            store.activeTerminalTheme.terminalBackgroundColor
                .ignoresSafeArea(.container, edges: [.horizontal, .top, .bottom])
        }
        .navigationDestination(isPresented: terminalArtifactIsPresented) {
            if let selectedTerminalArtifact {
                ChatArtifactViewerDestination(
                    path: selectedTerminalArtifact.path,
                    scope: selectedTerminalArtifact.usesSessionAuthorization ? .chat : .terminal
                ) {
                    self.selectedTerminalArtifact = nil
                }
                    .environment(
                        \.chatArtifactLoader,
                        artifactLoader(for: selectedTerminalArtifact)
                    )
            }
        }
        #else
        .background(store.activeTerminalTheme.terminalBackgroundColor)
        #endif
        #if !os(iOS)
        .navigationTitle(systemNavigationTitle)
        .mobileTerminalNavigationChrome(theme: store.activeTerminalTheme)
        .toolbar {
            ToolbarItem {
                terminalToolbarButtons
            }
        }
        #endif
    }

    private func reconnectToWorkspaceMac() {
        Task {
            await store.reconnectToMac(
                macDeviceID: workspace.macDeviceID,
                instanceTag: workspace.macInstanceTag
            )
        }
    }

    /// Same-client foreground recovery flips the store's recovery flags while
    /// `workspace.macConnectionStatus` stays `.connected`; the pill reflects
    /// the recovery. Input gating deliberately does NOT use this (see
    /// `terminalInputIsBlocked`): a probe's "Reconnecting" display coexists
    /// with a working keyboard. Hidden retained details keep their raw
    /// status: the guard only applies to the selected workspace on the
    /// foreground connection.
    private var effectiveConnectionStatus: MobileMacConnectionStatus {
        if store.selectedWorkspaceID == workspace.id,
           store.selectedWorkspaceUsesForegroundConnection {
            if store.connectionRecoveryFailed {
                return .unavailable
            }
            if store.isRecoveringConnection {
                return .reconnecting
            }
        }
        return connectionStatus
    }

    /// Input viability is narrower than the displayed status: a same-client
    /// probe reads "Reconnecting" while the transport is still connected and
    /// the RPC client still carries keystrokes, so blocking or resigning
    /// there would dismiss a working keyboard mid-typing. Block only when
    /// the workspace status itself is disconnected or foreground recovery
    /// actually failed. Internal so the +Surfaces chrome-return refocus can
    /// share the same policy.
    var terminalInputIsBlocked: Bool {
        if connectionStatus != .connected {
            return true
        }
        if store.selectedWorkspaceID == workspace.id,
           store.selectedWorkspaceUsesForegroundConnection,
           store.connectionRecoveryFailed {
            return true
        }
        return false
    }

    #if os(iOS)
    private func resignTerminalInputIfBlocked(_ isBlocked: Bool) {
        // resignActiveInput() acts on the process-wide active surface, and
        // hidden details retained by other tab stacks observe their own
        // status; only the selected workspace may resign it, or background
        // connection churn would steal the visible terminal's keyboard.
        guard store.selectedWorkspaceID == workspace.id else { return }
        if isBlocked {
            GhosttySurfaceView.resignActiveInput()
        }
    }
    #endif

    #if os(iOS)
    private var terminalArtifactIsPresented: Binding<Bool> {
        Binding(
            get: { selectedTerminalArtifact != nil },
            set: { isPresented in
                if !isPresented { selectedTerminalArtifact = nil }
            }
        )
    }

    func terminalArtifactLoader(workspaceID: String, surfaceID: String) -> ChatArtifactLoader {
        guard let source = store.makeChatEventSource() else {
            return .unsupported(cache: terminalArtifactThumbnailCache)
        }
        return ChatArtifactLoader(
            terminalWorkspaceID: workspaceID,
            terminalSurfaceID: surfaceID,
            supportsArtifacts: store.supportsTerminalArtifacts,
            supportsDirectoryBrowsing: store.supportsTerminalArtifactList,
            cache: terminalArtifactThumbnailCache,
            stat: { path in
                try await source.terminalArtifactStat(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    path: path
                )
            },
            fetch: { path, progress in
                try await source.terminalArtifactFetch(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    path: path,
                    progress: progress
                )
            },
            stream: { path, onChunk in
                try await source.terminalArtifactFetch(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    path: path,
                    onChunk: onChunk
                )
            },
            thumbnail: { path, maxDimension in
                try await source.terminalArtifactThumbnail(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    path: path,
                    maxDimension: maxDimension
                )
            },
            list: { path in
                try await source.terminalArtifactList(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    path: path
                )
            }
        )
    }

    private func artifactLoader(for selection: TerminalArtifactSelection) -> ChatArtifactLoader {
        guard let sessionID = selection.sessionID else {
            return terminalArtifactLoader(
                workspaceID: selection.workspaceID,
                surfaceID: selection.surfaceID
            )
        }
        guard store.supportsChatArtifacts,
              let source = store.makeChatEventSource() else {
            return .unsupported(cache: terminalArtifactThumbnailCache)
        }
        return ChatArtifactLoader(
            source: source,
            sessionID: sessionID,
            cache: terminalArtifactThumbnailCache
        )
    }
    #endif

    @ViewBuilder
    private var terminalToolbarButtons: some View {
        newWorkspaceToolbarButton
    }

    #if os(iOS)
    /// Leading back-button island; iOS 26 supplies toolbar glass.
    @ViewBuilder
    private var workspaceBackToolbarButton: some View {
        if let backButtonConfiguration {
            WorkspaceBackButton(
                unreadCount: backButtonConfiguration.unreadCount,
                badgeContrast: backButtonConfiguration.badgeContrast,
                action: backButtonConfiguration.action
            )
        }
    }

    #endif

    private var newWorkspaceToolbarButton: some View {
        Button(action: createWorkspaceFromToolbar) {
            Label(L10n.string("mobile.workspace.new", defaultValue: "New Workspace"), systemImage: "plus.square.on.square")
                .labelStyle(.iconOnly)
        }
        .foregroundStyle(store.activeTerminalTheme.terminalChromeForegroundColor)
        .disabled(!canCreateWorkspace)
        .accessibilityIdentifier("MobileTerminalNewWorkspaceButton")
    }

    var workspaceUtilitiesToolbarButton: some View {
        WorkspaceUtilitiesMenu(
            showsViewAsText: activeBrowser == nil && activeBrowserStream == nil && !isChatMode,
            showsPaneMap: workspace.layout != nil,
            browserStreamRows: browserStreamStore
                .panels(in: workspace.rpcWorkspaceID.rawValue)
                .map(BrowserStreamPickerRow.init),
            supportsBrowserStream: store.supportsBrowserStream,
            activeBrowserStreamPanelID: activeBrowserStream?.id,
            terminalTheme: store.activeTerminalTheme,
            selectBrowserStream: selectBrowserStreamFromToolbar,
            presentPaneMap: presentPaneMap,
            openTextSheet: openTextSheetFromMenu,
            copyDebugLogs: {
                #if DEBUG
                copyDebugLogsFromMenu()
                #endif
            },
            sendFeedback: openFeedbackComposerFromMenu
        )
    }

    private var surfaceDeckValue: SurfaceDeckValue {
        SurfaceDeckValue(
            workspace: workspace,
            selectedSurfaceID: selectedTerminal?.id.rawValue,
            agentStateKindsBySurfaceID: surfaceDeckAgentStateKinds,
            canCreateWorkspace: canCreateWorkspace
        )
    }

    private var surfaceDeckActions: SurfaceDeckActions {
        SurfaceDeckActions(
            selectTerminal: selectTerminalFromDeck,
            presentPaneMap: presentPaneMap,
            createTerminal: createTerminalFromToolbar,
            openBrowser: openBrowserFromToolbar,
            createWorkspace: createWorkspaceFromToolbar
        )
    }

    private var surfaceDeckAgentStateKinds: [String: ChatAgentStateKind] {
        var result: [String: ChatAgentStateKind] = [:]
        for session in store.cachedChatSessions(workspaceID: workspace.id.rawValue) {
            guard let terminalID = session.terminalID else { continue }
            switch session.state {
            case .working:
                result[terminalID] = .working
            case .needsInput:
                result[terminalID] = .needsInput
            case .idle, .ended:
                break
            }
        }
        return result
    }

    private func presentPaneMap() {
        guard workspace.layout != nil else { return }
        paneZoomPresentation.presentPaneMap(
            from: selectedTerminal?.id.rawValue
        )
    }

    private func presentTerminalFromPaneMap(_ terminalID: MobileTerminalPreview.ID) {
        paneZoomPresentation.presentTerminal(surfaceID: terminalID.rawValue)
        selectTerminalFromDeck(terminalID)
    }

    private func returnToTerminalFromPaneMap() {
        guard !paneZoomSourceSurfaceID.isEmpty else { return }
        paneZoomPresentation.presentTerminal(surfaceID: paneZoomSourceSurfaceID)
    }

    private func refreshPaneMapFromToolbar() {
        paneMapRefreshTrigger &+= 1
    }

    @MainActor
    private func reorderPanesFromMap(
        _ orderedPaneIDs: [String],
        baseLayoutRevision: Int
    ) async -> Bool {
        let result = await store.reorderWorkspacePanes(
            id: workspace.id,
            orderedPaneIDs: orderedPaneIDs,
            baseLayoutRevision: baseLayoutRevision
        )
        guard case .success = result else {
            toasts.present(.failure(
                L10n.string(
                    "mobile.paneMap.reorderFailed",
                    defaultValue: "Couldn’t rearrange panes on your Mac."
                ),
                coalescingKey: "pane-map.reorder-failed"
            ))
            return false
        }
        return true
    }

    #if canImport(UIKit)
    #if DEBUG
    private func copyDebugLogsFromMenu() {
        // Include "what the user sees" (the visible terminal text) above the
        // debug log so a pasted bug report shows the on-screen content too.
        Task { @MainActor in
            let terminalText = await GhosttySurfaceView.visibleTerminalSnapshot()
            let count = await MobileDebugLog.shared.copyToPasteboard(prepending: terminalText)
            MobileHapticFeedback().notification(.success)
            NSLog("cmux.terminal copied %d debug log lines + visible terminal to pasteboard", count)
        }
    }
    #endif

    /// Opens the "View as Text" sheet: the terminal's content as selectable
    /// plain text, because the render surface itself has no copy affordance.
    private func openTextSheetFromMenu() {
        textSheetSurfaceID = selectedTerminal?.id.rawValue
        isTextSheetPresented = true
    }

    private func openFeedbackComposerFromMenu() {
        feedbackText = ""
        feedbackErrorMessage = nil
        // A prior submission may still be in flight if the user dismissed the
        // sheet mid-send (Cancel stays enabled); reset so the reopened composer
        // does not render Send permanently disabled until that task times out.
        isSubmittingFeedback = false
        // Prefill the reply-to address with the signed-in email on the email
        // path; the privileged agent path never reads it.
        feedbackEmail = store.signedInUserEmail ?? ""
        isFeedbackComposerPresented = true
    }

    /// Whether the current submission will go straight to the agent (privileged
    /// `@manaflow.ai` user on an active connection) vs the email inbox.
    private var feedbackRoutesToAgent: Bool {
        store.currentFeedbackRoute == .privilegedAgent
    }

    // Release-safe Send Feedback composer. Privileged @manaflow.ai users on an
    // active connection ship a diagnostic bundle straight to the paired Mac's
    // agent sink; everyone else emails the feedback inbox. Either way the
    // submission is stamped with build type + version + device.
    private var feedbackComposer: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(feedbackComposerExplanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextField(
                    L10n.string("mobile.feedback.placeholder", defaultValue: "What happened?"),
                    text: $feedbackText,
                    axis: .vertical
                )
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("MobileFeedbackComposerField")
                if !feedbackRoutesToAgent {
                    TextField(
                        L10n.string("mobile.feedback.emailPlaceholder", defaultValue: "Your email"),
                        text: $feedbackEmail
                    )
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("MobileFeedbackComposerEmailField")
                }
                if let feedbackErrorMessage {
                    Text(feedbackErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("MobileFeedbackComposerError")
                }
                Spacer()
            }
            .padding(16)
            .navigationTitle(L10n.string("mobile.feedback.send", defaultValue: "Send Feedback"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.feedback.cancel", defaultValue: "Cancel")) {
                        isFeedbackComposerPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.feedback.sendAction", defaultValue: "Send"), action: submitFeedbackFromComposer)
                        .disabled(isSubmittingFeedback || !isFeedbackSubmittable)
                        .accessibilityIdentifier("MobileFeedbackComposerSend")
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var feedbackComposerExplanation: String {
        if feedbackRoutesToAgent {
            // Intentionally does not promise the structured event log: that log
            // is only captured in DEBUG builds, so a Release agent bundle carries
            // the debug log + visible terminal + your note, not the event trace.
            return L10n.string(
                "mobile.feedback.explanation.agent",
                defaultValue: "Sends diagnostics (debug log + visible terminal) and your note straight to the paired Mac."
            )
        }
        return L10n.string(
            "mobile.feedback.explanation.email",
            defaultValue: "Emails your feedback to the cmux team, stamped with your app version and device."
        )
    }

    private var isFeedbackSubmittable: Bool {
        let messageOK = !feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if feedbackRoutesToAgent {
            return messageOK
        }
        // The email route requires a valid reply-to address; the web route's
        // zod schema rejects an empty/invalid email with a 400.
        return messageOK && feedbackEmail.contains("@")
    }

    private func submitFeedbackFromComposer() {
        guard !isSubmittingFeedback, isFeedbackSubmittable else { return }
        isSubmittingFeedback = true
        feedbackErrorMessage = nil
        let note = feedbackText
        let email = feedbackEmail
        let routesToAgent = feedbackRoutesToAgent
        // Only the agent path reads the terminal/debug snapshots; reading them is
        // cheap and harmless on the email path, but skip the work when unused.
        // `visibleTerminalSnapshot()` reads off the output queue with a bounded
        // async deadline (never a main-thread `ghostty_surface_read_text`, which blanks the
        // terminal). The debug-log snapshot is awaited from its actor.
        Task { @MainActor in
            let terminalText = routesToAgent ? await GhosttySurfaceView.visibleTerminalSnapshot() : ""
            let debugLogText = routesToAgent ? await MobileDebugLog.shared.sink.snapshotWithCount().1 : ""
            let outcome = await store.submitFeedback(
                message: note,
                emailOverride: email,
                debugLogText: debugLogText,
                terminalText: terminalText
            )
            isSubmittingFeedback = false
            switch outcome {
            case .sentToAgent, .emailed:
                isFeedbackComposerPresented = false
                if toasts.isEnabled {
                    // The toast supplies the success haptic; presenting after
                    // the composer dismisses keeps it the single confirmation.
                    toasts.present(.success(L10n.string(
                        "mobile.feedback.sentToast",
                        defaultValue: "Feedback sent"
                    )))
                } else {
                    MobileHapticFeedback().notification(.success)
                }
            case .failed:
                MobileHapticFeedback().notification(.error)
                feedbackErrorMessage = L10n.string(
                    "mobile.feedback.error",
                    defaultValue: "Could not send feedback. Check your connection and try again."
                )
            }
        }
    }
    #endif

    private func createWorkspaceFromToolbar() {
        guard canCreateWorkspace else { return }
        dismissTerminalKeyboardForChrome()
        createWorkspace()
    }

    /// Arms the close-workspace confirmation. The actual close runs only after
    /// the user confirms, matching the workspace list's destructive-action UX.
    private func requestCloseWorkspaceFromMenu() {
        dismissTerminalKeyboardForChrome()
        isConfirmingClose = true
    }

    func confirmCloseWorkspaceFromMenu() {
        closeWorkspace?(workspace.id)
    }

    /// Toggle the current workspace's read state from the title menu.
    private func toggleWorkspaceReadStateFromMenu() {
        let id = workspace.id
        let markUnread = !workspace.hasUnread
        setWorkspaceUnread?(id, markUnread)
    }

    #if canImport(UIKit)
    private func presentRenameFromMenu() {
        dismissTerminalKeyboardForChrome()
        // Seed the dialog field with the current name each time it opens.
        renameText = workspace.name
        isRenamePresented = true
    }

    private func presentCustomizationFromMenu() {
        dismissTerminalKeyboardForChrome()
        isCustomizationPresented = true
    }

    /// Commit the rename dialog: forward the trimmed name to the Mac, which echoes
    /// it back via the authoritative list sync. Empty names are ignored.
    func commitRenameFromDialog() {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let id = workspace.id
        renameWorkspace?(id, trimmed)
    }
    #endif

    private func createTerminalFromToolbar() {
        dismissTerminalKeyboardForChrome()
        // Creating a terminal from the (shared) chrome must surface it. If a
        // browser pane is up, close it so `body` leaves the browser branch and
        // shows the new terminal instead of staying on the browser.
        browserStore.closeBrowser(for: workspace.id.rawValue)
        stopActiveBrowserStream()
        createTerminal()
    }

    private func openBrowserFromToolbar() {
        dismissTerminalKeyboardForChrome()
        // Opens (or reveals the existing) browser pane for this workspace. The
        // detail view flips to the browser because `activeBrowser` becomes
        // non-nil.
        browserStore.openBrowser(for: workspace.id.rawValue)
        stopActiveBrowserStream()
    }

    private func selectBrowserStreamFromToolbar(_ panelID: String) {
        dismissTerminalKeyboardForChrome()
        browserStore.closeBrowser(for: workspace.id.rawValue)
        if let previous = activeBrowserStream, previous.id != panelID {
            Task { await store.stopMobileBrowserStream(panelID: previous.id) }
        }
        _ = browserStreamStore.activate(panelID: panelID, in: workspace.rpcWorkspaceID.rawValue)
        Task { await store.startMobileBrowserStream(panelID: panelID) }
    }

    private func stopActiveBrowserStream() {
        guard let stream = activeBrowserStream else { return }
        browserStreamStore.deactivate(in: workspace.rpcWorkspaceID.rawValue)
        Task { await store.stopMobileBrowserStream(panelID: stream.id) }
    }

    private func selectTerminalFromDeck(_ terminalID: MobileTerminalPreview.ID) {
        dismissTerminalKeyboardForChrome()
        // Choosing a terminal returns from the browser pane (if up) to the
        // terminal. Closing the browser is enough to flip the detail view back.
        browserStore.closeBrowser(for: workspace.id.rawValue)
        stopActiveBrowserStream()
        // Switching from the deck is chrome, not a typing intent, so the
        // newly-selected surface must not grab the keyboard on attach. The
        // store suppresses the target's autofocus (and is a no-op when it is
        // already selected). A push-notification deep link uses the plain
        // `selectTerminal` path instead and is allowed to autofocus.
        store.selectTerminalFromChrome(terminalID)
    }

    func dismissTerminalKeyboardForChrome() {
        // Resign the terminal's hidden text input first so the surface clears
        // its keyboard geometry and recomputes full-height before chrome covers
        // it; then sweep any other responder across the scene.
        GhosttySurfaceView.resignActiveInput()
        UIApplication.shared.dismissMobileKeyboard()
    }
}
