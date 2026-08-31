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
    /// Whether the title menu offers manual Reconnect: only once the
    /// connection is unavailable (an active reconnect needs no manual entry),
    /// and never during reauthentication, whose blocking banner owns
    /// recovery.
    static func canReconnectFromTitleMenu(
        effectiveConnectionStatus: MobileMacConnectionStatus,
        connectionRequiresReauth: Bool
    ) -> Bool {
        effectiveConnectionStatus == .unavailable && !connectionRequiresReauth
    }

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
    let backButtonConfiguration: WorkspaceBackButtonConfiguration?
    let signOut: (@MainActor @Sendable () -> Void)?
    @Environment(BrowserSurfaceStore.self) var browserStore
    @Environment(BrowserStreamStore.self) var browserStreamStore
    @Environment(MobileSimulatorStreamStore.self) var simulatorStreamStore
    @Environment(MobileDisplaySettings.self) private var displaySettings
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.mobileChildPresentationProvider) private var childPresentationProvider
    @Environment(\.terminalFilesChipEnabled) var isTerminalFilesChipEnabled
    /// Drives the destructive close-workspace confirmation dialog.
    @State var isConfirmingClose = false
    #if canImport(UIKit)
    @State private var isFeedbackComposerPresented = false
    @State private var feedbackText = ""
    @State private var feedbackEmail = ""
    @State private var isSubmittingFeedback = false
    @State private var feedbackErrorMessage: String?
    @State private var isTextSheetPresented = {
        #if DEBUG
        AutoConnectMigrationUITestConfiguration.currentProcess?.initialModalHost
            == .workspaceDetailTerminalText
        #else
        false
        #endif
    }()
    /// Drives the rename-workspace dialog launched from the picker menu, and its
    /// editable text (seeded with the current name when presented).
    @State var isRenamePresented = false
    @State var renameText = ""
    /// Drives the shared workspace identity editor from the title menu.
    @State var isCustomizationPresented = false
    /// Live pane width for capping the leading glass title pill.
    @State private var contentWidth: CGFloat = 0
    // Rendered content width per trailing toolbar item, keyed by item. The
    // title's width cap subtracts the structurally visible items' widths so
    // they always fit and iOS never folds them into the overflow More menu
    // (no per-item priority exists below iOS 27). Only structural removal
    // deletes an entry (see the onChange handlers); a layout-driven
    // disappearance (overflow into More) cannot release a reservation and
    // make the collapse sticky.
    @State private var trailingToolbarItemWidths: [String: CGFloat] = [:]
    /// Ratchets on when the trailing cluster's content leaves the bar while
    /// the screen's own content is still on a window: the system folded it
    /// into the More menu, so the estimate reserves undershot this device's
    /// chrome. Never cleared for this view's lifetime; the extra recovery
    /// reserve un-collapses the bar.
    @State private var trailingToolbarCollapseDetected = false
    /// Live window-attachment flags shared with the UIKit probes; reference
    /// identity keeps event-time reads current where SwiftUI captures of
    /// value state would be stale.
    @State private var barPresence = WorkspaceBarPresence()
    /// Terminal captured for the current "View as Text" sheet presentation.
    @State private var textSheetSurfaceID: String?
    /// Identity of the in-flight New Browser creation. A late RPC result must
    /// not activate its panel over a selection the user made in the meantime,
    /// so completion applies only while its request is still current.
    @State private var browserCreateRequest: UUID?
    @State var terminalPickerRows: [TerminalPickerMenuRow] = []
    /// Local presenter identity remains separate from the artifact popover payload.
    @State var isTerminalArtifactFilesPresented = false
    @State var terminalArtifactFilesContext: TerminalArtifactContext?
    @State var selectedTerminalArtifact: TerminalArtifactSelection?
    @State var terminalArtifactThumbnailCache = ChatArtifactThumbnailCache()
    @State var visibleArtifactCount = 0
    /// Shared presentation state for the toolbar, title-menu, and hint entry points.
    @State var isWorkspaceChangesSheetPresented = false
    @State var workspaceChangesHint: MobileWorkspaceChangesHint?
    @State var artifactGalleryRefreshSignal = TerminalArtifactGalleryRefreshSignal.initial
    @Environment(\.scenePhase) var scenePhase
    #endif
    /// The active browser surface for this workspace, when a browser pane is open.
    var activeBrowser: BrowserSurfaceState? {
        browserStore.activeBrowser(for: workspace.id.rawValue)
    }
    var activeBrowserStream: BrowserStreamSurfaceState? {
        browserStreamStore.activeState(in: workspace.rpcWorkspaceID.rawValue)
    }
    var activeSimulatorStream: MobileSimulatorStreamSurfaceState? {
        simulatorStreamStore.activeState(in: workspace.rpcWorkspaceID.rawValue)
    }
    #if os(iOS)
    /// Uses the root modal owner in the live app and local state in previews.
    func resolvedPresentation(
        for child: MobileRootPresentationState.ChildPresentation,
        fallback: Binding<Bool>
    ) -> MobileChildSheetPresentation {
        childPresentationProvider?.presentation(for: child, fallback: fallback)
            ?? MobileChildSheetPresentation(isPresented: fallback)
    }

    private var feedbackPresentation: MobileChildSheetPresentation {
        resolvedPresentation(
            for: .workspaceDetail(.feedbackComposer),
            fallback: $isFeedbackComposerPresented
        )
    }

    private var textSheetPresentation: MobileChildSheetPresentation {
        resolvedPresentation(
            for: .workspaceDetail(.terminalText),
            fallback: $isTextSheetPresented
        )
    }

    var workspaceChangesPresentation: MobileChildSheetPresentation {
        resolvedPresentation(
            for: .workspaceDetail(.workspaceChanges),
            fallback: $isWorkspaceChangesSheetPresented
        )
    }

    private var customizationPresentation: MobileChildSheetPresentation {
        resolvedPresentation(
            for: .workspaceDetail(.customization),
            fallback: $isCustomizationPresented
        )
    }

    var showMissingFiles: Bool {
        displaySettings.showMissingFiles
    }
    var terminalFolderTapEnabled: Bool {
        displaySettings.terminalFolderTapEnabled
    }
    var activeSurface: WorkspaceActiveSurface {
        WorkspaceActiveSurface.derive(
            hasActiveBrowser: activeBrowser != nil,
            hasActiveBrowserStream: activeBrowserStream != nil,
            hasActiveSimulatorStream: activeSimulatorStream != nil,
            selectedMacSurface: workspace.selectedMacSurface(id: store.selectedMacSurfaceID)
        )
    }
    #endif
    var body: some View {
        let content = Group { detailSurfaceContent }

        #if os(iOS)
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
            .navigationTitle(systemNavigationTitle)
            .mobileTerminalNavigationChrome(theme: store.activeTerminalTheme)
            // The browser and chat surfaces scroll; without this the system
            // minimizes the whole bar into a floating "…" pill, unlike the
            // terminal surface, which has no system scroll view.
            .mobilePinnedNavigationBar()
            .trackBarPresence(barPresence)
            .toolbar { workspaceDetailToolbar }
            .task(id: workspace.rpcWorkspaceID.rawValue) {
                await store.refreshMobileBrowserPanels(workspaceID: workspace.rpcWorkspaceID.rawValue)
                syncSimulatorStreamPanels()
                store.refreshWorkspaceSelection()
            }
            .onChange(of: browserStreamStore.panelDiscoveryRevision(in: workspace.rpcWorkspaceID.rawValue)) { _, _ in
                store.refreshWorkspaceSelection()
            }
            .onChange(of: workspace.simulators) { _, _ in
                syncSimulatorStreamPanels()
                store.refreshWorkspaceSelection()
            }
            // Structural removal drops the item's retained measurement so a
            // returning item takes the fail-safe unmeasured reserve instead of
            // a stale width for its first layout pass. Layout-driven
            // disappearance (overflow into More) never flips these conditions,
            // so it cannot release a reservation and make the collapse sticky.
            .onChange(of: workspaceChangesAreAvailable) { _, isAvailable in
                if !isAvailable { trailingToolbarItemWidths["changes"] = nil }
            }
            .onChange(of: altScreenNoticeIsVisible) { _, isVisible in
                if !isVisible { trailingToolbarItemWidths["altscreen-notice"] = nil }
            }
            .onAppear { refreshWorkspaceChangesHint() }
            .onChange(of: workspaceChangesHintEligibilityKey) { _, _ in
                refreshWorkspaceChangesHint()
            }
            .onChange(of: selectedTerminalID) { _, _ in
                visibleArtifactCount = 0
                syncTerminalPickerRows(includeTitleChanges: true)
            }
            .onChange(of: store.supportsTerminalArtifacts) { _, supportsArtifacts in
                visibleArtifactCount = 0
            }
            .onChange(of: store.supportsChatArtifactGallery) { _, _ in
                visibleArtifactCount = 0
            }
            .closeWorkspaceConfirmation(
                isPresented: $isConfirmingClose,
                confirm: confirmCloseWorkspaceFromMenu
            )
            .sheet(
                isPresented: feedbackPresentation.isPresented,
                onDismiss: feedbackPresentation.didDismiss
            ) {
                feedbackComposer
            }
            .sheet(
                isPresented: textSheetPresentation.isPresented,
                onDismiss: {
                    textSheetSurfaceID = nil
                    textSheetPresentation.didDismiss()
                }
            ) {
                TerminalTextSheetView(surfaceID: textSheetSurfaceID)
            }
            .sheet(
                isPresented: workspaceChangesPresentation.isPresented,
                onDismiss: workspaceChangesPresentation.didDismiss
            ) {
                WorkspaceChangesSheet(
                    store: store,
                    workspaceID: workspace.rpcWorkspaceID.rawValue,
                    workspaceTitle: workspace.name
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .workspaceRenameDialog(
                isPresented: $isRenamePresented,
                text: $renameText,
                onSave: commitRenameFromDialog
            )
            .sheet(
                isPresented: customizationPresentation.isPresented,
                onDismiss: customizationPresentation.didDismiss
            ) {
                WorkspaceCustomizationSheet(workspace: workspace) { initialDraft, submittedDraft in
                    await customizeWorkspace?(workspace.id, initialDraft, submittedDraft)
                        ?? .failure()
                }
            }
            .mobileConnectionRecoveryOverlay(store: store, signOut: signOut)
        #else
        content
            .closeWorkspaceConfirmation(
                isPresented: $isConfirmingClose,
                confirm: confirmCloseWorkspaceFromMenu
            )
            .mobileConnectionRecoveryOverlay(store: store, signOut: signOut)
        #endif
    }

    #if os(iOS)
    private var altScreenNoticeIsVisible: Bool {
        guard let selectedTerminalID else { return false }
        return store.isAlternateScreen(surfaceID: selectedTerminalID)
            && displaySettings.showAltScreenNotice
    }

    @ToolbarContentBuilder
    private var workspaceDetailToolbar: some ToolbarContent {
        if backButtonConfiguration != nil {
            ToolbarItem(id: "workspace-back", placement: .topBarLeading) {
                workspaceBackToolbarButton
            }
            if #available(iOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .topBarLeading)
            }
        }
        ToolbarItem(id: "workspace-title", placement: .topBarLeading) {
            workspaceTitleToolbarMenu
        }
        // iOS 27's visibilityPriority(.high) natively keeps the trailing items
        // out of the overflow More menu. The symbols are absent from SDK 26.x,
        // so the branch is compiler-gated until an Xcode 27 toolchain builds
        // this target; the measured title cap below stays the sizing mechanism
        // on every OS (the native priority only decides who overflows, it does
        // not grant the title the remaining space).
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            highPriorityTrailingToolbarItems
        } else {
            trailingToolbarItems
        }
        #else
        trailingToolbarItems
        #endif
    }

    @ToolbarContentBuilder
    private var trailingToolbarItems: some ToolbarContent {
        if altScreenNoticeIsVisible {
            ToolbarItem(id: "workspace-altscreen-notice", placement: .topBarTrailing) {
                altScreenNoticeToolbarContent
            }
        }
        if workspaceChangesAreAvailable {
            ToolbarItem(id: "workspace-changes", placement: .topBarTrailing) {
                workspaceChangesToolbarContent
            }
        }
        ToolbarItem(id: "workspace-trailing", placement: .topBarTrailing) {
            trailingClusterToolbarContent
        }
    }

    #if compiler(>=6.4)
    @available(iOS 27.0, *)
    @ToolbarContentBuilder
    private var highPriorityTrailingToolbarItems: some ToolbarContent {
        if altScreenNoticeIsVisible {
            ToolbarItem(id: "workspace-altscreen-notice", placement: .topBarTrailing) {
                altScreenNoticeToolbarContent
            }
            .visibilityPriority(.high)
        }
        if workspaceChangesAreAvailable {
            ToolbarItem(id: "workspace-changes", placement: .topBarTrailing) {
                workspaceChangesToolbarContent
            }
            .visibilityPriority(.high)
        }
        ToolbarItem(id: "workspace-trailing", placement: .topBarTrailing) {
            trailingClusterToolbarContent
        }
        .visibilityPriority(.high)
    }
    #endif

    private var altScreenNoticeToolbarContent: some View {
        AltScreenNoticeButton {
            displaySettings.showAltScreenNotice = false
        }
        .measureTrailingToolbarItem("altscreen-notice", into: $trailingToolbarItemWidths)
    }

    private var workspaceChangesToolbarContent: some View {
        WorkspaceChangesToolbarButton(
            chip: workspaceChangesChip,
            workspaceID: workspace.rpcWorkspaceID.rawValue,
            action: openWorkspaceChanges
        )
        // The chrome sits on the terminal theme's background, not the
        // system scheme; resolve the counts' green/red for that.
        .environment(\.colorScheme, store.activeTerminalTheme.terminalColorScheme)
        .measureTrailingToolbarItem("changes", into: $trailingToolbarItemWidths)
    }

    private var trailingClusterToolbarContent: some View {
        terminalPickerToolbarButton
            .frame(width: 44, height: 44)
            // Only the always-structural cluster wires collapse detection: a
            // conditional item's structural removal also detaches its probe
            // and would be indistinguishable from a More-menu collapse.
            .measureTrailingToolbarItem(
                "trailing-cluster",
                into: $trailingToolbarItemWidths,
                onLeaveBar: {
                    // A deeper push or a pop detaches the whole screen, this
                    // content view included, before the bar items animate
                    // out; only a cluster detach while the content is still
                    // on a window is the More-menu collapse.
                    if barPresence.detailContentAttached {
                        trailingToolbarCollapseDetected = true
                    }
                }
            )
    }

    // Which trailing toolbar items are structurally in the bar right now.
    // Must mirror the conditions in trailingToolbarItems.
    private var structuralTrailingItemKeys: [String] {
        var keys = ["trailing-cluster"]
        if altScreenNoticeIsVisible { keys.append("altscreen-notice") }
        if workspaceChangesAreAvailable { keys.append("changes") }
        return keys
    }

    private var workspaceTitleToolbarMenu: some View {
        let measuredWidths = structuralTrailingItemKeys.compactMap { trailingToolbarItemWidths[$0] }
        // Reconnect lives in the title menu now that no pill covers the
        // terminal; reauthentication keeps its own blocking banner.
        let canReconnect = Self.canReconnectFromTitleMenu(
            effectiveConnectionStatus: effectiveConnectionStatus,
            connectionRequiresReauth: store.connectionRequiresReauth
        )
        let value = WorkspaceTitleMenuValue(
            contentWidth: contentWidth,
            hasBackButton: backButtonConfiguration != nil,
            hasTrailingCluster: true,
            measuredTrailingItemsWidth: measuredWidths.reduce(0, +),
            measuredTrailingItemCount: measuredWidths.count,
            trailingItemCount: structuralTrailingItemKeys.count,
            hadTrailingCollapse: trailingToolbarCollapseDetected,
            isEnabled: hasTitleMenuActions || canReconnect,
            workspaceName: workspace.name,
            hasUnread: workspace.hasUnread,
            canCustomizeWorkspace: customizeWorkspace != nil,
            canRenameWorkspace: renameWorkspace != nil,
            canToggleReadState: setWorkspaceUnread != nil,
            canCloseWorkspace: closeWorkspace != nil,
            canReconnect: canReconnect,
            labelToken: toolbarTitleLabelToken,
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
                    canReconnect: value.canReconnect,
                    presentCustomization: presentCustomizationFromMenu,
                    presentRename: presentRenameFromMenu,
                    toggleReadState: toggleWorkspaceReadStateFromMenu,
                    requestClose: requestCloseWorkspaceFromMenu,
                    reconnect: reconnectToWorkspaceMac
                )
            },
            label: {
                switch value.labelToken {
                case .standard(let title, let subtitle, let connectionStatus):
                    WorkspaceToolbarTitleView(
                        title: title,
                        subtitle: subtitle,
                        connectionStatus: connectionStatus
                    )
                }
            }
        )
        .equatable()
    }

    private var toolbarTitleLabelToken: WorkspaceTitleMenuLabelToken {
        let connectionStatus = effectiveConnectionStatus
        if let browser = activeBrowser {
            // Browser-style surfaces keep the workspace as the pill's title,
            // like the terminal; the surface's own title (the page or tab)
            // rides the subtitle line.
            return .standard(
                title: workspace.name,
                subtitle: browser.title,
                connectionStatus: connectionStatus
            )
        } else if let browser = activeBrowserStream {
            return .standard(
                title: workspace.name,
                subtitle: browser.title,
                connectionStatus: connectionStatus
            )
        } else if let simulator = activeSimulatorStream {
            return .standard(
                title: workspace.name,
                subtitle: simulator.selectedDeviceName ?? simulator.title,
                connectionStatus: connectionStatus
            )
        } else {
            return .standard(
                title: workspace.name,
                subtitle: selectedToolbarSubtitle,
                connectionStatus: connectionStatus
            )
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
        // The unavailable terminal stays visible; block interaction so
        // keystrokes aren't silently dropped once reconnect attempts stop.
        // A terminal that is merely reconnecting stays interactive (see
        // `terminalInputIsBlocked`). The status pill attaches after this
        // modifier and stays tappable.
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
        // No terminal-covering connection chrome: reconnecting is the title
        // bar's spinner, disconnected is the title's red dot + subtitle with
        // Reconnect in the title menu, and last-known content stays visible
        // throughout.
        #if os(iOS)
        .overlay(alignment: .topTrailing) {
            if let terminalID = selectedTerminal?.id.rawValue,
               !store.isComposerPresented {
                TerminalSendStatusPill(
                    status: store.terminalSendStatus(forTerminalID: terminalID)
                )
                .allowsHitTesting(false)
                .padding(.top, 10)
                .padding(.trailing, 10)
            }
        }
        #endif
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
        .terminalKeyboardGeometryProbe("detail-inside")
        .mobileTerminalSafeAreaExpansion(
            context: safeAreaContext,
            includesBottom: true
        )
        .terminalKeyboardGeometryProbe("detail-outside")
        .background {
            // Fill under translucent chrome with the terminal's own color.
            store.activeTerminalTheme.terminalBackgroundColor
                .ignoresSafeArea(.container, edges: [.horizontal, .top, .bottom])
        }
        .navigationDestination(isPresented: terminalArtifactIsPresented) {
            if let selectedTerminalArtifact {
                ChatArtifactViewerDestination(
                    path: selectedTerminalArtifact.path,
                    scope: .terminal
                ) {
                    self.selectedTerminalArtifact = nil
                }
                    .environment(
                        \.chatArtifactLoader,
                        terminalArtifactLoader(
                            workspaceID: selectedTerminalArtifact.workspaceID,
                            surfaceID: selectedTerminalArtifact.surfaceID
                        )
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

    func reconnectToWorkspaceMac() {
        Task {
            await store.reconnectToMac(
                macDeviceID: workspace.macDeviceID,
                instanceTag: workspace.macInstanceTag
            )
        }
    }

    /// Same-client foreground recovery flips the store's recovery flags while
    /// `workspace.macConnectionStatus` stays `.connected`; the title bar's
    /// spinner reflects the recovery. Input gating deliberately does NOT use
    /// this (see `terminalInputIsBlocked`): a probe's reconnecting display
    /// coexists with a working keyboard. Hidden retained details keep their
    /// raw status: the guard only applies to the selected workspace on the
    /// foreground connection.
    var effectiveConnectionStatus: MobileMacConnectionStatus {
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

    /// Input follows the effective (recovery-aware) status, not the raw row
    /// status: the redial path downgrades the retained row to unavailable in
    /// the same turn it marks the recovery as reconnecting, and gating on the
    /// raw value would resign a working keyboard right as the spinner starts.
    /// The terminal stays fully interactive while a reconnect is in flight so
    /// the user can finish typing a thought — keystrokes ride the send
    /// buffer, and a send that races the dead window fails visibly through
    /// the send-status pill instead of the keyboard dropping mid-word. Block
    /// only once the connection is unavailable (attempts stopped or
    /// foreground recovery failed, which `effectiveConnectionStatus` folds
    /// in). Internal so the +Surfaces chrome-return refocus can share the
    /// same policy.
    var terminalInputIsBlocked: Bool {
        effectiveConnectionStatus == .unavailable
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
            return .unsupported(
                cache: terminalArtifactThumbnailCache,
                diagnosticLog: store.diagnosticLog
            )
        }
        return ChatArtifactLoader(
            terminalWorkspaceID: workspaceID,
            terminalSurfaceID: surfaceID,
            supportsArtifacts: store.supportsTerminalArtifacts,
            supportsDirectoryBrowsing: store.supportsTerminalArtifactList,
            cache: terminalArtifactThumbnailCache,
            diagnosticLog: store.diagnosticLog,
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

    #endif

    @ViewBuilder
    private var terminalToolbarButtons: some View {
        newWorkspaceToolbarButton
        terminalPickerToolbarButton
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

    // Native menu keeps press-drag-release selection and routes through
    // `selectTerminalFromPicker`; keyboard-dismiss-on-open is unavailable.
    var terminalPickerToolbarButton: some View {
        TerminalPickerMenu(
            value: TerminalPickerMenuValue(
                liveTerminals: workspace.terminals,
                liveSurfaces: workspace.surfaces,
                snapshotRows: terminalPickerRows,
                selectedID: store.selectedTerminalID,
                // Resolved through the workspace so the auto-presented
                // fallback surface (no terminals, no explicit selection)
                // carries the picker checkmark like any picked surface.
                selectedMacSurfaceID: workspace.selectedMacSurface(id: store.selectedMacSurfaceID)?.id,
                canCreateWorkspace: canCreateWorkspace,
                hasActiveBrowser: activeBrowser != nil,
                browserStreamRows: browserStreamStore.panels(in: workspace.rpcWorkspaceID.rawValue).map(BrowserStreamPickerRow.init),
                supportsBrowserStream: store.supportsBrowserStream,
                activeBrowserStreamPanelID: activeBrowserStream?.id,
                simulatorStreamRows: simulatorStreamStore.panels(in: workspace.rpcWorkspaceID.rawValue).map(SimulatorStreamPickerRow.init),
                supportsSimulatorStream: store.supportsSimulatorStream,
                activeSimulatorStreamPanelID: activeSimulatorStream?.id
            ),
            actions: TerminalPickerMenuActions(
                selectTerminal: selectTerminalFromPicker,
                selectMacSurface: selectMacSurfaceFromPicker,
                createWorkspace: createWorkspaceFromToolbar,
                createTerminal: createTerminalFromToolbar,
                openBrowser: openBrowserFromToolbar,
                selectBrowserStream: { selectBrowserStreamFromToolbar($0) },
                selectSimulatorStream: selectSimulatorStreamFromToolbar,
                openTextSheet: openTextSheetFromMenu,
                copyDebugLogs: {
                    #if DEBUG
                    copyDebugLogsFromMenu()
                    #endif
                },
                sendFeedback: openFeedbackComposerFromMenu
            ),
            terminalTheme: store.activeTerminalTheme
        )
        .equatable()
        .simultaneousGesture(TapGesture().onEnded { syncTerminalPickerRows(includeTitleChanges: true) })
        .onAppear { syncTerminalPickerRows(includeTitleChanges: true) }
        .onChange(of: terminalPickerLiveMembership) { _, _ in syncTerminalPickerRows() }
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
        store.recordAppEvent(
            .terminalTextViewOpened,
            correlationID: selectedTerminal?.id.rawValue
        )
        textSheetPresentation.present {
            textSheetSurfaceID = selectedTerminal?.id.rawValue
        }
    }

    private func openFeedbackComposerFromMenu() {
        feedbackPresentation.present {
            feedbackText = ""
            feedbackErrorMessage = nil
            // A prior submission may still be in flight if the user dismissed the
            // sheet mid-send (Cancel stays enabled); reset so the reopened composer
            // does not render Send permanently disabled until that task times out.
            isSubmittingFeedback = false
            // Prefill the reply-to address with the signed-in email on the email
            // path; the privileged agent path never reads it.
            feedbackEmail = store.signedInUserEmail ?? ""
        }
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
                        feedbackPresentation.dismiss()
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
                feedbackPresentation.dismiss()
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

    /// Toggle the current workspace's read state from the picker menu.
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
        customizationPresentation.present {
            dismissTerminalKeyboardForChrome()
        }
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
        browserCreateRequest = nil
        // Creating a terminal from the (shared) chrome must surface it. If a
        // browser pane is up, close it so `body` leaves the browser branch and
        // shows the new terminal instead of staying on the browser.
        browserStore.closeBrowser(for: workspace.id.rawValue)
        stopActiveBrowserStream()
        stopActiveSimulatorStream()
        store.selectedMacSurfaceID = nil
        createTerminal()
    }

    private func openBrowserFromToolbar() {
        dismissTerminalKeyboardForChrome()
        // New Browser creates a real Mac browser pane and streams it, so it
        // shows the same surface as the Mac Browsers rows. The phone-local
        // WKWebView pane remains only as a fallback for Macs that cannot
        // create panels (older builds, disconnected, or creation rejected).
        guard store.supportsBrowserStreamCreate else {
            openLocalBrowserFallback()
            return
        }
        let workspaceID = workspace.rpcWorkspaceID.rawValue
        let request = UUID()
        browserCreateRequest = request
        Task {
            let descriptor = await store.createMobileBrowserPanel(workspaceID: workspaceID)
            guard browserCreateRequest == request else { return }
            browserCreateRequest = nil
            guard let descriptor else {
                openLocalBrowserFallback()
                return
            }
            selectBrowserStreamFromToolbar(descriptor.panelID, dismissKeyboard: false)
        }
    }

    /// Opens (or reveals) the phone-local browser pane for this workspace. The
    /// detail view flips to the browser because `activeBrowser` becomes
    /// non-nil; the picker shows a check next to "New Browser" while it is up.
    private func openLocalBrowserFallback() {
        let workspaceID = workspace.id.rawValue
        store.recordAppEvent(.browserCreateStarted, correlationID: workspaceID)
        _ = browserStore.openBrowser(for: workspaceID)
        store.recordAppEvent(.browserCreateSucceeded, correlationID: workspaceID)
        stopActiveBrowserStream()
        stopActiveSimulatorStream()
        store.selectedMacSurfaceID = nil
    }

    private func selectBrowserStreamFromToolbar(_ panelID: String, dismissKeyboard: Bool = true) {
        if dismissKeyboard {
            dismissTerminalKeyboardForChrome()
        }
        browserCreateRequest = nil
        browserStore.closeBrowser(for: workspace.id.rawValue)
        stopActiveSimulatorStream()
        store.selectedMacSurfaceID = nil
        if let previous = activeBrowserStream, previous.id != panelID {
            Task { await store.stopMobileBrowserStream(panelID: previous.id) }
        }
        _ = browserStreamStore.activate(panelID: panelID, in: workspace.rpcWorkspaceID.rawValue)
        Task { await store.startMobileBrowserStream(panelID: panelID) }
    }

    private func selectSimulatorStreamFromToolbar(_ panelID: String) {
        dismissTerminalKeyboardForChrome()
        browserStore.closeBrowser(for: workspace.id.rawValue)
        stopActiveBrowserStream()
        store.selectedMacSurfaceID = nil
        let workspaceID = workspace.rpcWorkspaceID.rawValue
        let previousPanelID: String? = activeSimulatorStream.flatMap {
            $0.id == panelID ? nil : $0.id
        }
        // Settle the previous panel's local state before activating the new
        // one, so switching A -> B leaves A idle instead of frozen on a stale
        // `.streaming`/`.starting` status.
        if let previousPanelID {
            simulatorStreamStore.deactivate(panelID: previousPanelID, in: workspaceID)
        }
        _ = simulatorStreamStore.activate(panelID: panelID, in: workspaceID)
        // One task, stop awaited before start: two independent tasks have no
        // ordering guarantee, and the reversed order would tear down the new
        // stream (or churn host sessions) right after it started.
        Task {
            if let previousPanelID {
                await store.stopMobileSimulatorStream(
                    panelID: previousPanelID,
                    workspaceID: workspaceID
                )
            }
            await store.startMobileSimulatorStream(
                panelID: panelID,
                workspaceID: workspaceID
            )
        }
    }

    private func stopActiveBrowserStream() {
        guard let stream = activeBrowserStream else { return }
        browserStreamStore.deactivate(in: workspace.rpcWorkspaceID.rawValue)
        Task { await store.stopMobileBrowserStream(panelID: stream.id) }
    }

    private func stopActiveSimulatorStream() {
        store.stopActiveMobileSimulatorStream(in: workspace.rpcWorkspaceID.rawValue)
    }

    private func selectTerminalFromPicker(_ terminalID: MobileTerminalPreview.ID) {
        dismissTerminalKeyboardForChrome()
        browserCreateRequest = nil
        // Choosing a terminal returns from the browser pane (if up) to the
        // terminal. Closing the browser is enough to flip the detail view back.
        browserStore.closeBrowser(for: workspace.id.rawValue)
        stopActiveBrowserStream()
        stopActiveSimulatorStream()
        store.selectedMacSurfaceID = nil
        // Switching from the picker is chrome, not a typing intent, so the
        // newly-selected surface must not grab the keyboard on attach. The
        // store suppresses the target's autofocus (and is a no-op when it is
        // already selected). A push-notification deep link uses the plain
        // `selectTerminal` path instead and is allowed to autofocus.
        store.selectTerminalFromChrome(terminalID)
    }

    private func selectMacSurfaceFromPicker(_ surfaceID: MobileSurfacePreview.ID) {
        dismissTerminalKeyboardForChrome()
        browserCreateRequest = nil
        browserStore.closeBrowser(for: workspace.id.rawValue)
        stopActiveBrowserStream()
        // Streams outrank Mac surfaces in `WorkspaceActiveSurface.derive`, so
        // a selected Simulator stream must be cleared before the Mac surface
        // can become visible.
        stopActiveSimulatorStream()
        store.selectMacSurface(surfaceID)
    }

    func dismissTerminalKeyboardForChrome() {
        // Resign the terminal's hidden text input first so the surface clears
        // its keyboard geometry and recomputes full-height before chrome covers
        // it; then sweep any other responder across the scene.
        GhosttySurfaceView.resignActiveInput()
        UIApplication.shared.dismissMobileKeyboard()
    }

    private func syncSimulatorStreamPanels() {
        simulatorStreamStore.replaceSimulatorPanels(
            in: workspace.rpcWorkspaceID.rawValue,
            with: workspace.simulators
        )
    }
}
