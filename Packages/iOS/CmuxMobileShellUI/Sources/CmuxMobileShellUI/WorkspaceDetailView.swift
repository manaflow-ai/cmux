import CmuxAgentChat
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
    let createTerminal: () -> Void
    /// Close this workspace on the Mac. When `nil` (older Macs without the
    /// `workspace.close.v1` capability, or previews) the close affordance is
    /// hidden from the top-bar menu. Mirrors the workspace list's gating.
    let closeWorkspace: ((MobileWorkspacePreview.ID) -> Void)?
    let reportTerminalViewport: (MobileWorkspacePreview.ID, MobileTerminalPreview.ID, MobileTerminalViewportSize) -> Void
    let sendTerminalInput: (String) -> Void
    let safeAreaContext: MobileTerminalSafeAreaContext
    /// Phone-local browser surfaces, injected from the app root. When this
    /// workspace has an active browser surface the detail view presents a
    /// browser pane in place of the terminal; otherwise it shows the terminal.
    @Environment(BrowserSurfaceStore.self) private var browserStore
    /// Drives the destructive close-workspace confirmation dialog launched from
    /// the top-bar menu. Owned here (not in the menu builder) so the dialog stays
    /// attached to the detail view across menu open/close cycles.
    @State private var isConfirmingClose = false
    #if canImport(UIKit)
    @State private var isFeedbackComposerPresented = false
    @State private var feedbackText = ""
    @State private var feedbackEmail = ""
    @State private var isSubmittingFeedback = false
    @State private var feedbackErrorMessage: String?
    @State private var isTextSheetPresented = false
    /// Drives the rename-workspace dialog launched from the picker menu, and its
    /// editable text (seeded with the current name when presented).
    @State private var isRenamePresented = false
    @State private var renameText = ""
    /// Live pane width, used to width-cap the centered glass title pill so a long
    /// workspace name truncates instead of underlapping the toolbar buttons.
    @State private var contentWidth: CGFloat = 0
    /// Captured at the moment the "View as Text" action is tapped so the
    /// sheet keeps showing the terminal the user asked about even if the
    /// workspace selection changes underneath it (e.g. Mac-side sync) while
    /// the sheet is open; the sheet loads its snapshot once per presentation.
    @State private var textSheetSurfaceID: String?
    /// Chat-mode toggle: when on (and a session exists) the detail renders
    /// the agent chat inline in place of the terminal. The toolbar button
    /// flips this; there is no cover and no Done button.
    @State private var isChatMode = false
    /// The session chat mode was entered on, pinned so a newer session
    /// sorting first cannot swap the conversation out from under the user
    /// mid-read. Cleared when chat mode turns off.
    @State private var pinnedChatSessionID: String?
    @State private var chatSessions: [ChatSessionDescriptor] = []
    /// Per-session composer drafts, surviving toggles back to the terminal.
    @State private var chatDrafts: [String: String] = [:]
    #endif

    private var selectedTerminal: MobileTerminalPreview? {
        workspace.terminals.first { $0.id == store.selectedTerminalID } ?? workspace.terminals.first
    }

    /// Extra blank top padding for the terminal/chat, on top of the safe area, so
    /// the first rows sit clear of the Dynamic Island / nav bar with breathing
    /// room instead of being jammed against them.
    private var terminalTopPadding: CGFloat { 20 }

    /// The active browser surface for this workspace, when a browser pane is open.
    private var activeBrowser: BrowserSurfaceState? {
        browserStore.activeBrowser(for: workspace.id.rawValue)
    }

    #if os(iOS)
    /// The chat session belonging to the currently visible tab/terminal, if
    /// any. The toggle and the chat bind to THIS — the tab the user is
    /// looking at — so a tab's chat never shows another tab's history, and a
    /// tab with no agent session yields nil (its toggle is hidden). A past
    /// agent that has since ended still matches here (its record keeps the
    /// terminal binding), so the tab keeps showing the conversation read-only.
    ///
    /// This per-tab match relies on surface ids being stable across app
    /// relaunch / session restore (cmux reuses a panel's persisted id when it
    /// is still unique), so the session's recorded terminal id keeps matching
    /// the live terminal.
    private var sessionForSelectedTerminal: ChatSessionDescriptor? {
        guard let terminalID = selectedTerminal?.id.rawValue else { return nil }
        return chatSessions.first { $0.terminalID == terminalID }
    }

    /// The session chat mode opens: the visible tab's session, or the pinned
    /// session while chat mode is on.
    private var chosenChatSession: ChatSessionDescriptor? {
        // While chat is open it is pinned to one session: return that exact
        // session or nil if it vanished — never silently switch to another
        // (the transcript/store can't follow that switch, so the header
        // would claim B while the conversation stays A). nil makes the body
        // fall back to the terminal and refreshChatSessions exit chat mode.
        if let pinnedChatSessionID {
            return chatSessions.first { $0.id == pinnedChatSessionID }
        }
        return sessionForSelectedTerminal
    }

    /// The tab/terminal name for a session, for the chat header subtitle.
    private func tabName(for session: ChatSessionDescriptor) -> String? {
        workspace.terminals.first { $0.id.rawValue == session.terminalID }?.name
    }
    #endif

    var body: some View {
        #if os(iOS)
        if isChatMode, let session = chosenChatSession {
            chatContent(session)
                // Emerge from the toolbar (top edge) rather than snapping in,
                // matching standard toolbar-driven transitions.
                .transition(.move(edge: .top).combined(with: .opacity))
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
    /// Agent chat rendered in place of the terminal while chat mode is on.
    /// Carries the same toolbar so the toggle (now filled) flips back.
    @ViewBuilder
    private func chatContent(_ session: ChatSessionDescriptor) -> some View {
        WorkspaceChatPane(
            session: session,
            store: store,
            workspaceName: workspace.name,
            tabName: tabName(for: session),
            draft: Binding(
                get: { chatDrafts[session.id] ?? "" },
                set: { chatDrafts[session.id] = $0 }
            ),
            onExitChat: {
                withAnimation(.snappy(duration: 0.28)) {
                    isChatMode = false
                }
                pinnedChatSessionID = nil
            }
        )
        // Bind the pane's identity to the session so a session change
        // rebuilds ChatScreen (its store is captured in @State at init and
        // would otherwise stay on the old session).
        .id(session.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Extra top inset so the first transcript rows clear the Dynamic Island /
        // nav bar instead of hiding behind the opaque top; content still scrolls
        // up under the glass.
        .safeAreaPadding(.top, terminalTopPadding)
        .mobileTerminalNavigationChrome()
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // Chat toggle stays top-level next to the picker (lets you flip
                // back to the terminal); New Workspace lives in the picker menu.
                chatToggleButton
                terminalPickerToolbarButton
            }
        }
        .task(id: chatRefreshKey) { await refreshChatSessions() }
        .workspaceRenameDialog(
            isPresented: $isRenamePresented,
            text: $renameText,
            onSave: commitRenameFromDialog
        )
    }

    /// Top-level toolbar toggle between terminal and chat. Shown only when the
    /// currently visible tab has an agent session (or chat is already on), so the
    /// toggle tracks the tab the user is looking at. Surface ids are stable across
    /// relaunch/restore, so this per-tab match survives a restart. It sits next to
    /// the terminal picker (where New Workspace used to be); the glass title pill
    /// keeps the center readable even with the button present.
    @ViewBuilder
    private var chatToggleButton: some View {
        if isChatMode || sessionForSelectedTerminal != nil {
            Button(action: toggleChatMode) {
                Image(systemName: isChatMode
                    ? "bubble.left.and.bubble.right.fill"
                    : "bubble.left.and.bubble.right")
            }
            .accessibilityLabel(L10n.string("mobile.workspace.agentChat", defaultValue: "Agent Chat"))
            .accessibilityIdentifier("MobileWorkspaceAgentChatButton")
            .disabled(!isChatMode && chosenChatSession == nil)
        }
    }

    /// Flip between the terminal and the inline agent chat, pinning/unpinning the
    /// chosen session. Shared by the (legacy) toolbar button and the menu row.
    private func toggleChatMode() {
        withAnimation(.snappy(duration: 0.28)) {
            isChatMode.toggle()
        }
        pinnedChatSessionID = isChatMode ? chosenChatSession?.id : nil
    }

    /// Identity for the session refetch: workspace plus connection epoch.
    private var chatRefreshKey: String {
        "\(workspace.id.rawValue)#\(store.connectionState == .connected ? 1 : 0)"
    }

    /// Keeps the chat-capable session list current while this workspace is
    /// shown, so the GUI toggle appears as soon as a coding agent becomes
    /// active, without polling. The Mac pushes a `chat.message` frame on
    /// every descriptor/state change (a brand-new agent emits
    /// `descriptorChanged`); we register the push stream first, seed the
    /// list once, then fold each subsequent frame in. Registering before
    /// seeding plus idempotent folds means a change that races the seed
    /// converges either way. The stream finishes when the connection drops;
    /// `.task(id: chatRefreshKey)` re-runs this on reconnect, and cancels it
    /// on workspace change or when the view goes away.
    private func refreshChatSessions() async {
        guard let source = store.makeChatEventSource() else {
            chatSessions = []
            applyChatModeFallback()
            return
        }
        let reducer = ChatSessionListReducer(workspaceID: workspace.id.rawValue)
        let stream = await source.sessionEvents()
        // Animate the list update so the toggle eases in rather than popping
        // when a session is found (the seed/first frame arriving over the
        // wire is the "appears real quickly but not smooth" moment).
        let seeded = (try? await source.sessions(workspaceID: workspace.id.rawValue)) ?? []
        withAnimation(.snappy(duration: 0.25)) { chatSessions = seeded }
        applyChatModeFallback()
        for await frame in stream {
            let next = reducer.applying(frame, to: chatSessions)
            withAnimation(.snappy(duration: 0.25)) { chatSessions = next }
            applyChatModeFallback()
        }
    }

    /// If the session backing chat mode disappeared, fall back to the
    /// terminal rather than showing an empty chat.
    private func applyChatModeFallback() {
        if isChatMode, chosenChatSession == nil {
            isChatMode = false
            pinnedChatSessionID = nil
        }
    }
    #endif

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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        .navigationTitle(browser.title ?? workspace.name)
        .mobileTerminalNavigationChrome()
        .toolbar {
            ToolbarItem(placement: .principal) {
                glassTitle(browser.title ?? workspace.name)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                chatToggleButton
                terminalPickerToolbarButton
            }
        }
        .task(id: chatRefreshKey) { await refreshChatSessions() }
        .closeWorkspaceConfirmation(
            isPresented: $isConfirmingClose,
            confirm: confirmCloseWorkspaceFromMenu
        )
        .workspaceRenameDialog(
            isPresented: $isRenamePresented,
            text: $renameText,
            onSave: commitRenameFromDialog
        )
    }
    #endif

    private func detailContent() -> some View {
        // `GhosttySurfaceView` owns the bottom accessory bar: it docks the
        // `TerminalInputAccessoryAction` toolbar persistently at the bottom
        // (above the keyboard when up, above the home indicator when down) and
        // reserves its height in the terminal grid. The SwiftUI bar that used to
        // live here has been removed so the two stacked toolbars from
        // dogfood iosfin no longer fight for the same screen edge.
        Group {
            #if os(iOS)
            if let terminalID = selectedTerminal?.id.rawValue {
                GhosttySurfaceRepresentable(
                    surfaceID: terminalID,
                    store: store,
                    fontSize: MobileTerminalFontPreference.defaultSize,
                    // While the composer is presented the terminal input proxy
                    // must not grab first responder on attach. This covers both
                    // composer states: mid-compose (the field owns the keyboard
                    // and a surface re-create from switching terminals must not
                    // steal it back) and the default-open presentation (the field
                    // is visible but unfocused — iMessage semantics — so the
                    // keyboard stays DOWN until the user taps the terminal or the
                    // field).
                    autoFocusOnWindowAttach: store.shouldAutoFocusTerminalSurface(terminalID)
                        && !store.isComposerPresented,
                    isComposerActive: store.isComposerPresented
                )
                // Identity must track the selected terminal. The representable's
                // coordinator binds its byte sink to the surfaceID at make time and
                // `updateUIView` is a no-op, so without a per-terminal id SwiftUI
                // reuses the first terminal's surface and the dropdown never switches.
                // Keying on terminalID tears down the old surface (unregistering its
                // sink via dismantleUIView) and builds the newly-selected one.
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
                // Keep the grid INSIDE the top safe area and add extra blank top
                // padding so the first rows sit clear of the Dynamic Island and
                // the nav bar instead of being stuck in the non-visible area
                // behind them. The padded region shows the terminal background
                // (the window-filling `.background` below extends under the bar),
                // so it reads as blank terminal color, and the glass title pill
                // floats over it.
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
        #if os(iOS)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        #endif
        .overlay(alignment: .topLeading) {
            MobileMacConnectionStatusPill(host: host, status: connectionStatus)
                .padding(.top, 10)
                .padding(.leading, 10)
        }
        #if os(iOS) && DEBUG
        // Store-side composer seam (DEBUG/UI-test only): exposes the source-of-truth
        // store flags that drive the surface's composer mirror, so a UI test can assert
        // the store and surface agree across repeated open/close cycles and that the
        // draft (`terminalInputText`) survives. Zero-size + read live on every query;
        // never compiled into a shipping build. Pairs with `MobileComposerDockProbe`
        // on the surface side.
        .overlay {
            ComposerStoreProbe(
                isComposerPresented: store.isComposerPresented,
                composerFocusRequest: store.composerFocusRequest,
                draftLength: store.terminalInputText.count
            )
        }
        #endif
        #if os(iOS)
        // The whole bottom dock (terminal grid / composer band / accessory toolbar /
        // keyboard) is owned by `GhosttySurfaceView` in one coordinate system. The
        // iMessage composer is mounted INTO the surface's composer band by
        // `GhosttySurfaceRepresentable` (a `UIHostingController`), not added here as a
        // `safeAreaInset`. There is no second layout system reaching into the
        // surface's bottom, so the accessory toolbar can never be reparented out (its
        // buttons can never disappear) and a composer-grow pushes only the terminal up.
        .mobileTerminalSafeAreaExpansion(
            context: safeAreaContext,
            includesBottom: true
        )
        .background {
            // Fill the whole window, including under the translucent nav bar, so
            // the glass tints the terminal's own dark color rather than the page
            // background.
            TerminalPalette.background
                .ignoresSafeArea(.container, edges: [.horizontal, .top, .bottom])
        }
        #else
        .background(TerminalPalette.background)
        #endif
        .navigationTitle(workspace.name)
        .mobileTerminalNavigationChrome()
        #if os(iOS)
        .task(id: chatRefreshKey) { await refreshChatSessions() }
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .principal) {
                glassTitle(workspace.name)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                chatToggleButton
                terminalPickerToolbarButton
            }
            #else
            ToolbarItem {
                terminalToolbarButtons
            }
        #endif
        }
        .closeWorkspaceConfirmation(
            isPresented: $isConfirmingClose,
            confirm: confirmCloseWorkspaceFromMenu
        )
        #if canImport(UIKit)
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
        #endif
    }

    @ViewBuilder
    private var terminalToolbarButtons: some View {
        newWorkspaceToolbarButton
        terminalPickerToolbarButton
    }

    #if os(iOS)
    /// A nav-bar title on its own Liquid Glass capsule (iOS 26+) so it stays
    /// readable over the pane showing through the cleared header bar. On iOS 18
    /// the bar keeps a material background, so `mobileGlassNavigationTitle` is a
    /// no-op and this renders as plain text.
    private func glassTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(TerminalPalette.foreground)
            // Centered principal item: cap it to the clear center gap so a long
            // name truncates instead of underlapping the bar buttons, but reserve
            // only the actual side clusters (not a flat 300pt) so the middle grows
            // as much as it safely can.
            .frame(maxWidth: MobileNavTitleWidth.cap(
                contentWidth: contentWidth,
                hasChatToggle: isChatMode || sessionForSelectedTerminal != nil
            ))
            .mobileGlassNavigationTitle()
    }
    #endif

    private var newWorkspaceToolbarButton: some View {
        Button(action: createWorkspaceFromToolbar) {
            Label(L10n.string("mobile.workspace.new", defaultValue: "New Workspace"), systemImage: "plus.square.on.square")
                .labelStyle(.iconOnly)
        }
        .foregroundStyle(TerminalPalette.foreground)
        .accessibilityIdentifier("MobileTerminalNewWorkspaceButton")
    }

    // The picker is a native SwiftUI `Menu`, which renders as the platform menu
    // (a `UIMenu` on iOS). That gives the standard menu gesture for free: a
    // single tap opens it, and a press-and-drag from the button onto an item
    // followed by a release selects that item. The previous `Button` +
    // `.popover` was two separate hit-test sessions (tap to present, then tap an
    // item), so it never supported press-drag-release. Selection still routes
    // through `selectTerminalFromPicker`, which dismisses the keyboard, so the
    // chrome behavior is preserved; only keyboard-dismiss-on-open is dropped
    // because `Menu` has no will-open hook (the menu simply floats over the live
    // keyboard like any nav-bar menu).
    private var terminalPickerToolbarButton: some View {
        Menu {
            terminalPickerMenuContent
        } label: {
            Label(
                selectedTerminal?.name ?? L10n.string("mobile.terminal.select", defaultValue: "Terminal"),
                systemImage: "terminal"
            )
            .labelStyle(.iconOnly)
        }
        .foregroundStyle(TerminalPalette.foreground)
        .accessibilityIdentifier("MobileTerminalDropdown")
        .accessibilityValue(host)
    }

    @ViewBuilder
    private var terminalPickerMenuContent: some View {
        Section(L10n.string("mobile.terminal.picker.title", defaultValue: "Terminals")) {
            ForEach(workspace.terminals) { terminal in
                Button {
                    selectTerminalFromPicker(terminal.id)
                } label: {
                    Label(
                        terminal.name,
                        systemImage: terminal.id == selectedTerminal?.id && activeBrowser == nil
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

        // Rename the current workspace from the terminal-icon menu, mirroring the
        // workspace list's rename action. Gated on the same capability the list
        // uses, so it stays hidden on older Macs.
        if store.supportsWorkspaceActions {
            Section {
                Button(action: presentRenameFromMenu) {
                    Label(
                        L10n.string("mobile.workspace.rename.title", defaultValue: "Rename Workspace"),
                        systemImage: "pencil"
                    )
                }
                .accessibilityIdentifier("MobileWorkspaceRenameMenuItem")
            }
        }

        // Mark the current workspace read/unread from the terminal-icon menu,
        // mirroring the workspace list's swipe action. Only when the Mac supports
        // read-state actions, so it stays hidden on older Macs.
        if store.supportsWorkspaceReadStateActions {
            Section {
                Button(action: toggleWorkspaceReadStateFromMenu) {
                    Label(
                        workspace.hasUnread
                            ? L10n.string("mobile.workspace.markRead", defaultValue: "Mark as Read")
                            : L10n.string("mobile.workspace.markUnread", defaultValue: "Mark as Unread"),
                        systemImage: workspace.hasUnread ? "envelope.open" : "envelope.badge"
                    )
                }
                .accessibilityIdentifier("MobileWorkspaceMarkReadStateMenuItem")
            }
        }

        if closeWorkspace != nil {
            Section {
                Button(role: .destructive, action: requestCloseWorkspaceFromMenu) {
                    Label(
                        L10n.string("mobile.workspace.close.action", defaultValue: "Close Workspace"),
                        systemImage: "xmark.square"
                    )
                }
                .accessibilityIdentifier("MobileCloseWorkspaceMenuItem")
            }
        }

        #if canImport(UIKit)
        Section {
            // Only while the terminal pane is showing: in browser mode the
            // terminal surface is dismantled (nothing to capture) and the
            // sheet modifier lives on `detailContent`, so the armed flag
            // would pop the sheet later when the browser closes.
            if activeBrowser == nil {
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
                // DEV-only debug tooling; not shipped, so not localized.
                Label("Copy Debug Logs", systemImage: "doc.on.clipboard")
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

    #if canImport(UIKit)
    #if DEBUG
    private func copyDebugLogsFromMenu() {
        // Include "what the user sees" (the visible terminal text) above the
        // debug log so a pasted bug report shows the on-screen content too.
        let terminalText = GhosttySurfaceView.visibleTerminalSnapshot()
        Task { @MainActor in
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
        // wait (never a main-thread `ghostty_surface_read_text`, which blanks the
        // terminal). The debug-log snapshot is awaited from its actor.
        let terminalText = routesToAgent ? GhosttySurfaceView.visibleTerminalSnapshot() : ""
        Task { @MainActor in
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
        dismissTerminalKeyboardForChrome()
        createWorkspace()
    }

    /// Arms the close-workspace confirmation. The actual close runs only after
    /// the user confirms, matching the workspace list's destructive-action UX.
    private func requestCloseWorkspaceFromMenu() {
        dismissTerminalKeyboardForChrome()
        isConfirmingClose = true
    }

    private func confirmCloseWorkspaceFromMenu() {
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
    private func commitRenameFromDialog() {
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
