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
    let reportTerminalViewport: (MobileWorkspacePreview.ID, MobileTerminalPreview.ID, MobileTerminalViewportSize) -> Void
    let sendTerminalInput: (String) -> Void
    let safeAreaContext: MobileTerminalSafeAreaContext
    /// Phone-local browser surfaces, injected from the app root. When this
    /// workspace has an active browser surface the detail view presents a
    /// browser pane in place of the terminal; otherwise it shows the terminal.
    @Environment(BrowserSurfaceStore.self) private var browserStore
    #if canImport(UIKit)
    @State private var isFeedbackComposerPresented = false
    @State private var feedbackText = ""
    @State private var feedbackEmail = ""
    @State private var isSubmittingFeedback = false
    @State private var feedbackErrorMessage: String?
    @State private var isTextSheetPresented = false
    /// Captured at the moment the "View as Text" action is tapped so the
    /// sheet keeps showing the terminal the user asked about even if the
    /// workspace selection changes underneath it (e.g. Mac-side sync) while
    /// the sheet is open; the sheet loads its snapshot once per presentation.
    @State private var textSheetSurfaceID: String?
    #endif

    private var selectedTerminal: MobileTerminalPreview? {
        workspace.terminals.first { $0.id == store.selectedTerminalID } ?? workspace.terminals.first
    }

    /// The active browser surface for this workspace, when a browser pane is open.
    private var activeBrowser: BrowserSurfaceState? {
        browserStore.activeBrowser(for: workspace.id.rawValue)
    }

    var body: some View {
        #if os(iOS)
        if let browser = activeBrowser {
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
        .navigationTitle(browser.title ?? workspace.name)
        .mobileTerminalNavigationChrome()
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                newWorkspaceToolbarButton
                terminalPickerToolbarButton
            }
        }
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
            TerminalPalette.background
                .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
        }
        #else
        .background(TerminalPalette.background)
        #endif
        .navigationTitle(workspace.name)
        .mobileTerminalNavigationChrome()
        .toolbar {
            #if os(iOS)
            ToolbarItemGroup(placement: .topBarTrailing) {
                newWorkspaceToolbarButton
                terminalPickerToolbarButton
            }
            #else
            ToolbarItem {
                terminalToolbarButtons
            }
        #endif
        }
        #if canImport(UIKit)
        .sheet(isPresented: $isFeedbackComposerPresented) {
            feedbackComposer
        }
        .sheet(isPresented: $isTextSheetPresented) {
            TerminalTextSheetView(surfaceID: textSheetSurfaceID)
        }
        #endif
    }

    @ViewBuilder
    private var terminalToolbarButtons: some View {
        newWorkspaceToolbarButton
        terminalPickerToolbarButton
    }

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
