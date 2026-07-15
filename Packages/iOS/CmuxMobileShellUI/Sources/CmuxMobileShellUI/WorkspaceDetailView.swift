import CmuxAgentChat
import CmuxAgentChatUI
import CmuxMobileBrowser
import CmuxMobileDiagnostics
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileTerminal
import CmuxMobileWorkspace
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

struct WorkspaceDetailView: View {
    let host: String
    let connectionStatus: MobileMacConnectionStatus
    let workspace: MobileWorkspacePreview
    @Bindable var store: CMUXMobileShellStore
    let createWorkspace: () -> Void
    let canCreateWorkspace: Bool
    let createTerminal: () -> Void
    let renameWorkspace: ((MobileWorkspacePreview.ID, String) -> Void)?
    let setWorkspaceUnread: ((MobileWorkspacePreview.ID, Bool) -> Void)?
    /// Close this workspace on the Mac. When `nil`, the close affordance is
    /// hidden from the top-bar menu, matching the workspace list's gating.
    let closeWorkspace: ((MobileWorkspacePreview.ID) -> Void)?
    let reportTerminalViewport: (MobileWorkspacePreview.ID, MobileTerminalPreview.ID, MobileTerminalViewportSize) -> Void
    let sendTerminalInput: (String) -> Void
    let safeAreaContext: MobileTerminalSafeAreaContext
    let backButtonConfiguration: WorkspaceBackButtonConfiguration?
    let signOut: (() -> Void)?
    @Environment(BrowserSurfaceStore.self) var browserStore
    @Environment(MobileDisplaySettings.self) var displaySettings
    /// Drives the destructive close-workspace confirmation dialog.
    @State var isConfirmingClose = false
    #if canImport(UIKit)
    @State var isFeedbackComposerPresented = false
    @State var feedbackText = ""
    @State var feedbackEmail = ""
    @State var isSubmittingFeedback = false
    @State var feedbackErrorMessage: String?
    @State private var isTextSheetPresented = false
    /// Drives the rename-workspace dialog launched from the picker menu, and its
    /// editable text (seeded with the current name when presented).
    @State var isRenamePresented = false
    @State var renameText = ""
    /// Live pane width for capping the leading glass title pill.
    @State private var contentWidth: CGFloat = 0
    /// Terminal captured for the current "View as Text" sheet presentation.
    @State private var textSheetSurfaceID: String?
    @State var terminalPickerRows: [TerminalPickerMenuRow] = []
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
    /// Drives the one shared native-diff presentation path.
    @State var isWorkspaceDiffPresented = false
    @State var terminalArtifactFilesContext: TerminalArtifactContext?
    @State var selectedTerminalArtifact: TerminalArtifactSelection?
    @State var terminalArtifactThumbnailCache = ChatArtifactThumbnailCache()
    @State var visibleArtifactCount = 0
    /// App lifecycle phase used to re-pull chat sessions on foreground.
    @Environment(\.scenePhase) var scenePhase
    #endif
    /// The active browser surface for this workspace, when a browser pane is open.
    var activeBrowser: BrowserSurfaceState? {
        browserStore.activeBrowser(for: workspace.id.rawValue)
    }
    #if os(iOS)
    var activeSurface: WorkspaceActiveSurface {
        WorkspaceActiveSurface.derive(
            isChatMode: isChatMode,
            hasChosenChatSession: chosenChatSession != nil,
            hasActiveBrowser: activeBrowser != nil
        )
    }
    #endif
    var body: some View {
        let content = Group { detailSurfaceContent }

        #if os(iOS)
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
            .navigationTitle(systemNavigationTitle)
            .mobileTerminalNavigationChrome()
            .toolbar { workspaceDetailToolbar }
            .task(id: chatRefreshKey) { await refreshChatSessions() }
            .task(id: chatConversationWarmKey) { await runWarmChatConversation() }
            .onChange(of: selectedTerminalID) { _, _ in
                visibleArtifactCount = 0
                refreshCachedChatToggleAnchor()
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
            .sheet(isPresented: $isFeedbackComposerPresented) {
                feedbackComposer
            }
            .sheet(isPresented: $isTextSheetPresented) {
                TerminalTextSheetView(surfaceID: textSheetSurfaceID)
            }
            .sheet(isPresented: $isWorkspaceDiffPresented) {
                workspaceDiffPresentation
            }
            .workspaceRenameDialog(
                isPresented: $isRenamePresented,
                text: $renameText,
                onSave: commitRenameFromDialog
            )
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
        if workspaceDiffEntryGate.canPresent {
            ToolbarItem(id: "workspace-changes", placement: .topBarTrailing) {
                Button(action: presentWorkspaceDiff) {
                    Label(workspaceChangesLabel, systemImage: "doc.text.magnifyingglass")
                        .labelStyle(.iconOnly)
                }
                .accessibilityIdentifier("MobileWorkspaceChangesButton")
            }
        }
        if let selectedTerminalID,
           store.isAlternateScreen(surfaceID: selectedTerminalID),
           displaySettings.showAltScreenNotice {
            ToolbarItem(id: "workspace-altscreen-notice", placement: .topBarTrailing) {
                AltScreenNoticeButton {
                    displaySettings.showAltScreenNotice = false
                }
            }
        }
        ToolbarItem(id: "workspace-trailing", placement: .topBarTrailing) {
            toolbarTrailingCluster
        }
    }

    private var workspaceTitleToolbarMenu: some View {
        WorkspaceTitleMenu(
            contentWidth: contentWidth,
            hasBackButton: backButtonConfiguration != nil,
            hasTrailingCluster: true,
            hasChatToggle: shouldShowChatToggle,
            isEnabled: hasTitleMenuActions,
            menuContent: { titleMenuContent }
        ) {
            toolbarTitleLabel
        }
    }
    @ViewBuilder
    private var toolbarTitleLabel: some View {
        if isChatMode,
           let session = chosenChatSession,
           let conversation = chatConversationStores[session.id] {
            HStack(spacing: 4) {
                ChatSessionHeaderView(
                    descriptor: conversation.descriptor,
                    agentState: conversation.agentState,
                    isConnected: conversation.isConnected,
                    titleOverride: workspace.name,
                    subtitle: tabName(for: session),
                    style: .toolbarCompact
                )
                if showsDebugDiffEntryPoints {
                    Button(action: presentWorkspaceDiff) {
                        Image(systemName: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(workspaceChangesLabel)
                    .accessibilityIdentifier("MobileSessionSummaryChangesButton")
                }
            }
        } else if let browser = activeBrowser {
            Text(browser.title ?? workspace.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(TerminalPalette.foreground)
        } else {
            WorkspaceToolbarTitleView(title: workspace.name, subtitle: selectedToolbarSubtitle)
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
                TerminalPalette.background
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            #else
            TerminalPalette.background
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            MobileMacConnectionStatusPill(host: host, status: connectionStatus)
                .padding(.top, 10)
                .padding(.leading, 10)
        }
        .overlay {
            // Show a reconnecting/offline state instead of a black terminal.
            if connectionStatus != .connected {
                TerminalDisconnectedOverlay(status: connectionStatus, host: host) {
                    Task {
                        if let macDeviceID = workspace.macDeviceID,
                           !macDeviceID.isEmpty,
                           await store.switchToMac(macDeviceID: macDeviceID) {
                            return
                        }
                        await store.reconnectOrRefresh()
                    }
                }
            }
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
            TerminalPalette.background
                .ignoresSafeArea(.container, edges: [.horizontal, .top, .bottom])
        }
        .sheet(item: $selectedTerminalArtifact) { selection in
            ChatArtifactViewerSheet(path: selection.path, scope: .terminal)
                .environment(
                    \.chatArtifactLoader,
                    terminalArtifactLoader(
                        workspaceID: selection.workspaceID,
                        surfaceID: selection.surfaceID
                    )
                )
        }
        #else
        .background(TerminalPalette.background)
        #endif
        #if !os(iOS)
        .navigationTitle(systemNavigationTitle)
        .mobileTerminalNavigationChrome()
        .toolbar {
            ToolbarItem {
                terminalToolbarButtons
            }
        }
        #endif
    }

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

    var titleMenuContent: some View {
        WorkspaceTitleMenuContent(
            workspace: workspace,
            canRenameWorkspace: renameWorkspace != nil,
            canToggleReadState: setWorkspaceUnread != nil,
            canCloseWorkspace: closeWorkspace != nil,
            presentRename: presentRenameFromMenu,
            toggleReadState: toggleWorkspaceReadStateFromMenu,
            requestClose: requestCloseWorkspaceFromMenu
        )
    }

    #endif

    private var newWorkspaceToolbarButton: some View {
        Button(action: createWorkspaceFromToolbar) {
            Label(L10n.string("mobile.workspace.new", defaultValue: "New Workspace"), systemImage: "plus.square.on.square")
                .labelStyle(.iconOnly)
        }
        .foregroundStyle(TerminalPalette.foreground)
        .disabled(!canCreateWorkspace)
        .accessibilityIdentifier("MobileTerminalNewWorkspaceButton")
    }

    // Native menu keeps press-drag-release selection and routes through
    // `selectTerminalFromPicker`; keyboard-dismiss-on-open is unavailable.
    var terminalPickerToolbarButton: some View {
        TerminalPickerMenu(
            value: TerminalPickerMenuValue(
                liveTerminals: workspace.terminals,
                snapshotRows: terminalPickerRows,
                selectedID: store.selectedTerminalID,
                canCreateWorkspace: canCreateWorkspace,
                hasActiveBrowser: activeBrowser != nil,
                isChatMode: isChatMode
            ),
            actions: TerminalPickerMenuActions(
                selectTerminal: selectTerminalFromPicker,
                createWorkspace: createWorkspaceFromToolbar,
                createTerminal: createTerminalFromToolbar,
                openBrowser: openBrowserFromToolbar,
                openTextSheet: openTextSheetFromMenu,
                copyDebugLogs: {
                    #if DEBUG
                    copyDebugLogsFromMenu()
                    #endif
                },
                sendFeedback: openFeedbackComposerFromMenu
            )
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
            UINotificationFeedbackGenerator().notificationOccurred(.success)
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
        createTerminal()
    }

    private func openBrowserFromToolbar() {
        dismissTerminalKeyboardForChrome()
        // Opens (or reveals the existing) browser pane for this workspace. The
        // detail view flips to the browser because `activeBrowser` becomes
        // non-nil; the picker shows a check next to "New Browser" while it is up.
        browserStore.openBrowser(for: workspace.id.rawValue)
    }

    private func selectTerminalFromPicker(_ terminalID: MobileTerminalPreview.ID) {
        dismissTerminalKeyboardForChrome()
        // Choosing a terminal returns from the browser pane (if up) to the
        // terminal. Closing the browser is enough to flip the detail view back.
        browserStore.closeBrowser(for: workspace.id.rawValue)
        // Switching from the picker is chrome, not a typing intent, so the
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
