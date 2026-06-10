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
    #if DEBUG && canImport(UIKit)
    @State private var isFeedbackComposerPresented = false
    @State private var feedbackText = ""
    @State private var isSubmittingFeedback = false
    #endif

    private var selectedTerminal: MobileTerminalPreview? {
        workspace.terminals.first { $0.id == store.selectedTerminalID } ?? workspace.terminals.first
    }

    var body: some View {
        detailContent()
    }

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
                    autoFocusOnWindowAttach: store.shouldAutoFocusTerminalSurface(terminalID)
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
        #if os(iOS)
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
        #if DEBUG && canImport(UIKit)
        .sheet(isPresented: $isFeedbackComposerPresented) {
            feedbackComposer
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
                        systemImage: terminal.id == selectedTerminal?.id ? "checkmark.circle.fill" : "terminal"
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
        }

        #if DEBUG && canImport(UIKit)
        Section {
            Button(action: copyDebugLogsFromMenu) {
                // DEV-only debug tooling; not shipped, so not localized.
                Label("Copy Debug Logs", systemImage: "doc.on.clipboard")
            }
            .accessibilityIdentifier("MobileCopyDebugLogsMenuItem")

            Button(action: openFeedbackComposerFromMenu) {
                // DEV-only debug tooling; not shipped, so not localized.
                Label("Send to agent", systemImage: "paperplane")
            }
            .accessibilityIdentifier("MobileSendFeedbackMenuItem")
        }
        #endif
    }

    #if DEBUG && canImport(UIKit)
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

    private func openFeedbackComposerFromMenu() {
        feedbackText = ""
        isFeedbackComposerPresented = true
    }

    // DEV-only dogfood feedback composer; not shipped, so its strings are not
    // localized. Lets the dogfooder type an optional note and ship the structured
    // diagnostic log + debug log + visible terminal text to the paired Mac.
    private var feedbackComposer: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Send a structured diagnostic bundle (events + debug log + visible terminal) to the paired Mac. Add an optional note.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextField("What happened? (optional)", text: $feedbackText, axis: .vertical)
                    .lineLimit(3...8)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("MobileFeedbackComposerField")
                Spacer()
            }
            .padding(16)
            .navigationTitle("Send to agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isFeedbackComposerPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send", action: submitFeedbackFromComposer)
                        .disabled(isSubmittingFeedback)
                        .accessibilityIdentifier("MobileFeedbackComposerSend")
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func submitFeedbackFromComposer() {
        guard !isSubmittingFeedback else { return }
        isSubmittingFeedback = true
        let note = feedbackText
        // `visibleTerminalSnapshot()` reads off the output queue with a bounded
        // wait (never a main-thread `ghostty_surface_read_text`, which blanks the
        // terminal). The debug-log snapshot is awaited from its actor.
        let terminalText = GhosttySurfaceView.visibleTerminalSnapshot()
        Task { @MainActor in
            defer {
                isSubmittingFeedback = false
                isFeedbackComposerPresented = false
            }
            let (_, debugLogText) = await MobileDebugLog.shared.sink.snapshotWithCount()
            let ok = await store.submitDogfoodFeedback(
                text: note,
                debugLogText: debugLogText,
                terminalText: terminalText
            )
            UINotificationFeedbackGenerator().notificationOccurred(ok ? .success : .error)
            NSLog("cmux.dogfood feedback submit ok=%@", ok ? "1" : "0")
        }
    }
    #endif

    private func createWorkspaceFromToolbar() {
        dismissTerminalKeyboardForChrome()
        createWorkspace()
    }

    private func createTerminalFromToolbar() {
        dismissTerminalKeyboardForChrome()
        createTerminal()
    }

    private func selectTerminalFromPicker(_ terminalID: MobileTerminalPreview.ID) {
        dismissTerminalKeyboardForChrome()
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
