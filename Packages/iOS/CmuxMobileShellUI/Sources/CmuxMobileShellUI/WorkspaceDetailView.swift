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
    /// Close this workspace on the Mac. When `nil` (older Macs without the
    /// `workspace.close.v1` capability, or previews) the close affordance is
    /// hidden from the top-bar menu. Mirrors the workspace list's gating.
    let closeWorkspace: ((MobileWorkspacePreview.ID) -> Void)?
    let reportTerminalViewport: (MobileWorkspacePreview.ID, MobileTerminalPreview.ID, MobileTerminalViewportSize) -> Void
    let sendTerminalInput: (String) -> Void
    let safeAreaContext: MobileTerminalSafeAreaContext
    let backButtonConfiguration: WorkspaceBackButtonConfiguration?
    let signOut: (() -> Void)?
    /// Phone-local browser surfaces, injected from the app root.
    @Environment(BrowserSurfaceStore.self) private var browserStore
    /// Drives the destructive close-workspace confirmation dialog.
    @State var isConfirmingClose = false
    #if canImport(UIKit)
    @State private var isFeedbackComposerPresented = false
    @State private var feedbackText = ""
    @State private var feedbackEmail = ""
    @State private var isSubmittingFeedback = false
    @State private var feedbackErrorMessage: String?
    @State private var isTextSheetPresented = false
    /// Drives the rename-workspace dialog launched from the picker menu, and its
    /// editable text (seeded with the current name when presented).
    @State var isRenamePresented = false
    @State var renameText = ""
    /// Live pane width for capping the leading glass title pill.
    @State private var contentWidth: CGFloat = 0
    /// Terminal captured for the current "View as Text" sheet presentation.
    @State private var textSheetSurfaceID: String?
    @State private var terminalPickerRows: [TerminalPickerMenuRow] = []
    /// Chat-mode toggle for inline agent chat in place of the terminal.
    @State var isChatMode = false
    /// The session chat mode was entered on, pinned so a newer session
    /// sorting first cannot swap the conversation out from under the user
    /// mid-read. Cleared when chat mode turns off.
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
    /// App lifecycle phase used to re-pull chat sessions on foreground.
    @Environment(\.scenePhase) var scenePhase
    #endif
    /// The active browser surface for this workspace, when a browser pane is open.
    private var activeBrowser: BrowserSurfaceState? {
        browserStore.activeBrowser(for: workspace.id.rawValue)
    }

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
                refreshCachedChatToggleAnchor()
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
            ChatSessionHeaderView(
                descriptor: conversation.descriptor,
                agentState: conversation.agentState,
                isConnected: conversation.isConnected,
                titleOverride: workspace.name,
                subtitle: tabName(for: session),
                style: .toolbarCompact
            )
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

    @ViewBuilder
    private var detailSurfaceContent: some View {
        #if os(iOS)
        if isChatMode, let session = chosenChatSession {
            chatContent(session)
                .transition(.opacity)
        } else if let browser = activeBrowser {
            browserContent(browser)
        } else {
            detailContent()
        }
        #else
        detailContent()
        #endif
    }

    #if os(iOS)
    /// The browser pane shown when this workspace has an active browser surface.
    /// It carries its own navigation chrome, so it does not get the terminal's
    /// keyboard/safe-area handling. Closing returns to the terminal.
    @ViewBuilder
    private func browserContent(_ browser: BrowserSurfaceState) -> some View {
        MobileBrowserPane(
            state: browser,
            onClose: { browserStore.closeBrowser(for: workspace.id.rawValue) }
        )
        // Key on the surface id so switching/reopening rebuilds the WKWebView.
        .id(browser.id.rawValue)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    #endif

    private func detailContent() -> some View {
        // `GhosttySurfaceView` owns the bottom accessory bar and reserves its
        // height in the terminal grid.
        Group {
            #if os(iOS)
            if let terminalID = selectedTerminal?.id.rawValue {
                GhosttySurfaceRepresentable(
                    surfaceID: terminalID,
                    store: store,
                    fontSize: MobileTerminalFontPreference.defaultSize,
                    // Do not let a terminal reattach steal focus while the
                    // composer owns or intentionally withholds the keyboard.
                    autoFocusOnWindowAttach: store.shouldAutoFocusTerminalSurface(terminalID)
                        && !store.isComposerPresented,
                    isComposerActive: store.isComposerPresented,
                    // Drives the live recolor: when the synced theme changes the
                    // shell bumps this, and the representable rebuilds the runtime
                    // config + recolors the mounted surface in place (background,
                    // letterbox, default cell colors) without a remount, so
                    // scrollback survives a theme change.
                    themeGeneration: store.terminalThemeGeneration
                )
                // Identity must track the selected terminal. The representable's
                // coordinator binds its byte sink to the surfaceID at make time and
                // `updateUIView` is a no-op, so without a per-terminal id SwiftUI
                // reuses the first terminal's surface and the dropdown never switches.
                // Keying on terminalID tears down the old surface (unregistering its
                // sink via dismantleUIView) and builds the newly-selected one.
                //
                // The theme is NOT folded into the identity: a theme change recolors
                // the live surface in place (config rebuild + view recolor driven by
                // `themeGeneration`), so remounting would only throw away scrollback
                // for no visual benefit.
                .id(terminalID)
                .onAppear {
                    store.consumeTerminalAutoFocusSuppression(for: terminalID)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(TerminalPalette.background)
                // The surface positions its grid + docked toolbar from
                // `keyboardHeight` directly, so opt out of SwiftUI keyboard
                // avoidance; otherwise the view ALSO shrinks for the keyboard
                // and the reservation double-counts (extra gap when open).
                .ignoresSafeArea(.keyboard, edges: .bottom)
                // Keep the grid clear of the Dynamic Island and nav bar.
                .padding(.top, terminalTopPadding)
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
        let liveRows = terminalPickerLiveRows
        let rows = terminalPickerRows.isEmpty ? liveRows : terminalPickerRows
        let selection = rows.resolvedTerminalPickerSelection(selectedID: store.selectedTerminalID)

        return Menu {
            terminalPickerMenuContent(rows: rows, selectedID: selection?.id)
        } label: {
            Label(
                selection?.name ?? L10n.string("mobile.terminal.select", defaultValue: "Terminal"),
                systemImage: "rectangle.stack"
            )
            .labelStyle(.iconOnly)
        }
        .foregroundStyle(TerminalPalette.foreground)
        .accessibilityLabel(L10n.string("mobile.terminal.picker.title", defaultValue: "Terminals"))
        .accessibilityIdentifier("MobileTerminalDropdown")
        .accessibilityValue(selection?.name ?? "")
        .onAppear(perform: syncTerminalPickerRows)
        .onChange(of: liveRows) { _, _ in syncTerminalPickerRows() }
    }

    @ViewBuilder
    private func terminalPickerMenuContent(
        rows: [TerminalPickerMenuRow],
        selectedID: MobileTerminalPreview.ID?
    ) -> some View {
        Section(L10n.string("mobile.terminal.picker.title", defaultValue: "Terminals")) {
            ForEach(rows) { terminal in
                Button {
                    selectTerminalFromPicker(terminal.id)
                } label: {
                    Label(
                        terminal.name,
                        systemImage: terminal.id == selectedID && activeBrowser == nil
                            ? "checkmark.circle.fill"
                            : "terminal"
                    )
                }
                .accessibilityIdentifier("MobileTerminalMenuItem-\(terminal.id.rawValue)")
            }
        }

        Section {
            Button(action: createWorkspaceFromToolbar) {
                Label(L10n.string("mobile.workspace.new", defaultValue: "New Workspace"), systemImage: "plus.square.on.square")
            }
            .disabled(!canCreateWorkspace)
            .accessibilityIdentifier("MobileNewWorkspaceMenuItem")

            Button(action: createTerminalFromToolbar) {
                Label(L10n.string("mobile.terminal.new", defaultValue: "New Terminal"), systemImage: "plus")
            }
            .accessibilityIdentifier("MobileNewTerminalMenuItem")

            Button(action: openBrowserFromToolbar) {
                Label(
                    L10n.string("mobile.browser.new", defaultValue: "New Browser"),
                    systemImage: activeBrowser == nil ? "globe" : "checkmark.circle.fill"
                )
            }
            .accessibilityIdentifier("MobileNewBrowserMenuItem")
        }

        #if canImport(UIKit)
        Section {
            // Only while the terminal pane is showing: browser and chat modes
            // do not mount a terminal surface for text capture.
            if activeBrowser == nil && !isChatMode {
                Button(action: openTextSheetFromMenu) {
                    Label(
                        L10n.string("mobile.terminal.viewAsText", defaultValue: "View as Text"),
                        systemImage: "doc.plaintext"
                    )
                }
                .accessibilityIdentifier("MobileViewAsTextMenuItem")
            }

            #if DEBUG
            Button(action: copyDebugLogsFromMenu) {
                Label(L10n.string("mobile.debug.copyLogs", defaultValue: "Copy Debug Logs"), systemImage: "doc.on.clipboard")
            }
            .accessibilityIdentifier("MobileCopyDebugLogsMenuItem")
            #endif

            Button(action: openFeedbackComposerFromMenu) {
                Label(
                    L10n.string("mobile.feedback.send", defaultValue: "Send Feedback"),
                    systemImage: "paperplane"
                )
            }
            .accessibilityIdentifier("MobileSendFeedbackMenuItem")
        }
        #endif
    }

    private func syncTerminalPickerRows() {
        let rows = terminalPickerLiveRows
        guard terminalPickerRows != rows else { return }
        terminalPickerRows = rows
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
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                isFeedbackComposerPresented = false
            case .failed:
                UINotificationFeedbackGenerator().notificationOccurred(.error)
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

    /// Toggle the current workspace's read state on the Mac from the picker menu.
    /// Flips relative to the workspace's current `hasUnread`; the authoritative
    /// list re-sync inside `setWorkspaceUnread` reconciles the row + back-button
    /// count.
    private func toggleWorkspaceReadStateFromMenu() {
        let store = store
        let id = workspace.id
        let markUnread = !workspace.hasUnread
        Task { await store.setWorkspaceUnread(id: id, markUnread) }
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
        let store = store
        let id = workspace.id
        Task { await store.renameWorkspace(id: id, title: trimmed) }
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

    private func dismissTerminalKeyboardForChrome() {
        // Resign the terminal's hidden text input first so the surface clears
        // its keyboard geometry and recomputes full-height before chrome covers
        // it; then sweep any other responder across the scene.
        GhosttySurfaceView.resignActiveInput()
        UIApplication.shared.dismissMobileKeyboard()
    }
}
