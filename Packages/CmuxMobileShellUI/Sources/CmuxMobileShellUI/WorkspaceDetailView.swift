import CmuxAuthRuntime
import CmuxMobileDiagnostics
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileTerminal
import CmuxMobileWorkspace
import SwiftUI
#if os(iOS)
import CmuxMobileFeedback
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

struct WorkspaceDetailView: View {
    @Environment(AuthCoordinator.self) private var authManager
    let host: String
    let connectionStatus: MobileMacConnectionStatus
    let workspace: MobileWorkspacePreview
    @Bindable var store: CMUXMobileShellStore
    @Binding var selectedTerminalID: MobileTerminalPreview.ID?
    let createWorkspace: () -> Void
    let createTerminal: () -> Void
    let reportTerminalViewport: (MobileWorkspacePreview.ID, MobileTerminalPreview.ID, MobileTerminalViewportSize) -> Void
    let sendTerminalInput: (String) -> Void
    let safeAreaContext: MobileTerminalSafeAreaContext
    #if os(iOS)
    let feedbackClient: any MobileFeedbackSubmitting
    #endif
    @State private var isTerminalPickerPresented = false
    #if canImport(UIKit)
    @State private var diagnosticsReport: MobileDiagnosticsReport?
    @State private var diagnosticsPreparationTask: Task<MobileDiagnosticsReport, Never>?
    @State private var diagnosticsShareSheetItem: MobileDiagnosticsActivityItem?
    @State private var pendingDiagnosticsShareSheetItem: MobileDiagnosticsActivityItem?
    @State private var isPreparingDiagnostics = false
    @State private var isFeedbackComposerPresented = false
    @State private var shouldPresentFeedbackAfterPickerDismisses = false
    #endif

    private var selectedTerminal: MobileTerminalPreview? {
        workspace.terminals.first { $0.id == selectedTerminalID } ?? workspace.terminals.first
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
                    fontSize: MobileTerminalFontPreference.defaultSize
                )
                // Identity must track the selected terminal. The representable's
                // coordinator binds its byte sink to the surfaceID at make time and
                // `updateUIView` is a no-op, so without a per-terminal id SwiftUI
                // reuses the first terminal's surface and the dropdown never switches.
                // Keying on terminalID tears down the old surface (unregistering its
                // sink via dismantleUIView) and builds the newly-selected one.
                .id(terminalID)
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
        #if canImport(UIKit)
        .sheet(item: $diagnosticsShareSheetItem) { item in
            MobileDiagnosticsActivityView(item: item)
        }
        .sheet(isPresented: $isFeedbackComposerPresented) {
            MobileFeedbackComposerSheet(
                initialDiagnosticsReport: diagnosticsReport,
                buildDiagnosticsReport: buildDiagnosticsReport,
                client: feedbackClient
            )
            .presentationDetents([.large])
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

    private var terminalPickerToolbarButton: some View {
        Button {
            dismissTerminalKeyboardForChrome()
            #if canImport(UIKit)
            diagnosticsReport = nil
            diagnosticsPreparationTask?.cancel()
            diagnosticsPreparationTask = nil
            pendingDiagnosticsShareSheetItem = nil
            isPreparingDiagnostics = false
            #endif
            isTerminalPickerPresented = true
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
        .popover(isPresented: $isTerminalPickerPresented, arrowEdge: .top) {
            terminalPickerPopoverContent
        }
    }

    @ViewBuilder
    private var terminalPickerPopoverContent: some View {
        #if canImport(UIKit)
        terminalPickerContent
            .onDisappear(perform: presentPendingFeedbackComposerIfNeeded)
        #else
        terminalPickerContent
        #endif
    }

    private var terminalPickerContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.string("mobile.terminal.picker.title", defaultValue: "Terminals"))
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            ForEach(workspace.terminals) { terminal in
                Button {
                    selectTerminalFromPicker(terminal.id)
                } label: {
                    Label(
                        terminal.name,
                        systemImage: terminal.id == selectedTerminal?.id ? "checkmark.circle.fill" : "terminal"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .accessibilityIdentifier("MobileTerminalMenuItem-\(terminal.id.rawValue)")
            }

            Divider()
                .padding(.vertical, 4)

            Button(action: createWorkspaceFromTerminalPicker) {
                Label(L10n.string("mobile.workspace.new", defaultValue: "New Workspace"), systemImage: "plus.square.on.square")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityIdentifier("MobileNewWorkspaceMenuItem")

            Button(action: createTerminalFromToolbar) {
                Label(L10n.string("mobile.terminal.new", defaultValue: "New Terminal"), systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityIdentifier("MobileNewTerminalMenuItem")

            #if canImport(UIKit)
            Divider()
                .padding(.vertical, 4)

            diagnosticsCopyButton
            diagnosticsShareButton
            diagnosticsFeedbackButton
            #endif
        }
        .frame(minWidth: 240, maxWidth: 320, alignment: .leading)
        .presentationCompactAdaptation(.popover)
    }

    #if canImport(UIKit)
    /// Copies the assembled, scrubbed diagnostics report to the clipboard.
    @ViewBuilder
    private var diagnosticsCopyButton: some View {
        Button {
            Task { await copyDiagnosticsToPasteboard() }
        } label: {
            diagnosticsActionLabel(
                title: L10n.string("mobile.diagnostics.copy", defaultValue: "Copy Diagnostics"),
                systemImage: "doc.on.clipboard"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPreparingDiagnostics)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // Preserve the historical accessibility id so existing automation that
        // taps the debug-log export keeps working.
        .accessibilityIdentifier("MobileCopyDebugLogsMenuItem")
    }

    /// Shares the assembled, scrubbed diagnostics report.
    ///
    /// `ShareLink` needs the shared item synchronously. Once a report is cached
    /// this renders as a real `ShareLink`; the initial tap builds the report
    /// from the explicit user action and presents the same iOS activity sheet.
    @ViewBuilder
    private var diagnosticsShareButton: some View {
        if let report = diagnosticsReport {
            ShareLink(
                item: report.text,
                preview: SharePreview(
                    L10n.string("mobile.diagnostics.shareTitle", defaultValue: "cmux Diagnostics")
                )
            ) {
                Label(
                    L10n.string("mobile.diagnostics.share", defaultValue: "Share Diagnostics"),
                    systemImage: "square.and.arrow.up"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityIdentifier("MobileShareDiagnosticsMenuItem")
        } else {
            Button {
                Task { await prepareAndPresentDiagnosticsShareSheet() }
            } label: {
                diagnosticsActionLabel(
                    title: isPreparingDiagnostics
                        ? L10n.string("mobile.diagnostics.preparing", defaultValue: "Preparing Diagnostics…")
                        : L10n.string("mobile.diagnostics.share", defaultValue: "Share Diagnostics"),
                    systemImage: "square.and.arrow.up"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isPreparingDiagnostics)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityIdentifier("MobileShareDiagnosticsMenuItem")
        }
    }

    /// Opens the feedback form that emails the scrubbed diagnostics report
    /// through the same backend feedback flow used by the macOS app.
    private var diagnosticsFeedbackButton: some View {
        Button(action: presentFeedbackComposer) {
            Label(
                L10n.string("mobile.feedback.open", defaultValue: "Send Feedback"),
                systemImage: "paperplane"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityIdentifier("MobileSendFeedbackMenuItem")
    }
    #endif

    #if canImport(UIKit)
    private func diagnosticsActionLabel(title: String, systemImage: String) -> Label<Text, Image> {
        Label(title, systemImage: systemImage)
    }

    /// The shell's live runtime state, mapped into the decoupled diagnostics
    /// snapshot the report builder consumes.
    private var diagnosticsLiveState: MobileDiagnosticsLiveState {
        let host = store.connectedHostName.isEmpty ? nil : store.connectedHostName
        let activeTicket = store.activeTicket
        let activePairedMac = store.activePairedMac
        return MobileDiagnosticsLiveState(
            connectionState: diagnosticsConnectionState,
            isSignedIn: store.isSignedIn,
            isAuthenticated: authManager.isAuthenticated,
            lastAuthError: authManager.lastAuthErrorDescription,
            connectedHostName: host,
            pairedMacName: activeTicket?.macDisplayName
                ?? activePairedMac?.displayName
                ?? activeTicket?.macDeviceID
                ?? activePairedMac?.macDeviceID,
            pairedMacDeviceID: activeTicket?.macDeviceID ?? activePairedMac?.macDeviceID,
            connectionError: store.connectionError
        )
    }

    private var diagnosticsConnectionState: String {
        switch store.connectionState {
        case .connected:
            return "connected"
        case .disconnected:
            return "disconnected"
        }
    }

    /// Builds the report after the user chooses a diagnostics action, so the
    /// terminal picker itself stays a cheap navigation control.
    @MainActor
    private func prepareDiagnosticsReport() async -> MobileDiagnosticsReport {
        if let diagnosticsReport {
            return diagnosticsReport
        }
        if let diagnosticsPreparationTask {
            let report = await diagnosticsPreparationTask.value
            diagnosticsReport = report
            self.diagnosticsPreparationTask = nil
            isPreparingDiagnostics = false
            return report
        }

        isPreparingDiagnostics = true
        let task = Task { @MainActor in
            await buildDiagnosticsReport()
        }
        diagnosticsPreparationTask = task
        let report = await task.value
        diagnosticsReport = report
        diagnosticsPreparationTask = nil
        isPreparingDiagnostics = false
        return report
    }

    @MainActor
    private func prepareAndPresentDiagnosticsShareSheet() async {
        let report = await prepareDiagnosticsReport()
        pendingDiagnosticsShareSheetItem = .init(text: report.text)
        isTerminalPickerPresented = false
    }

    /// Builds the diagnostics report (in-process log + OS log + live state +
    /// visible terminal, then scrubbed).
    @MainActor
    private func buildDiagnosticsReport() async -> MobileDiagnosticsReport {
        let terminalText = GhosttySurfaceView.visibleTerminalSnapshot()
        let liveState = diagnosticsLiveState
        let environment = MobileDiagnosticsEnvironment.current()
        let builder = MobileDiagnosticsReportBuilder(
            environment: environment,
            sink: MobileDebugLog.shared.sink
        )
        return await builder.buildReport(
            liveState: liveState,
            terminalSnapshot: terminalText,
            immediateEventLines: store.diagnosticsImmediateEventLines
        )
    }

    /// Copies the prepared diagnostics text to the system pasteboard.
    @MainActor
    private func copyDiagnosticsToPasteboard() async {
        let report = await prepareDiagnosticsReport()
        isTerminalPickerPresented = false
        UIPasteboard.general.string = report.text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Presents the mobile feedback form with the current diagnostics report.
    private func presentFeedbackComposer() {
        shouldPresentFeedbackAfterPickerDismisses = true
        isTerminalPickerPresented = false
    }

    private func presentPendingFeedbackComposerIfNeeded() {
        if let pendingDiagnosticsShareSheetItem {
            self.pendingDiagnosticsShareSheetItem = nil
            diagnosticsShareSheetItem = pendingDiagnosticsShareSheetItem
            return
        }
        guard shouldPresentFeedbackAfterPickerDismisses else { return }
        shouldPresentFeedbackAfterPickerDismisses = false
        isFeedbackComposerPresented = true
    }
    #endif

    private func createWorkspaceFromToolbar() {
        dismissTerminalKeyboardForChrome()
        createWorkspace()
    }

    private func createWorkspaceFromTerminalPicker() {
        dismissTerminalKeyboardForChrome()
        isTerminalPickerPresented = false
        createWorkspace()
    }

    private func createTerminalFromToolbar() {
        dismissTerminalKeyboardForChrome()
        isTerminalPickerPresented = false
        createTerminal()
    }

    private func selectTerminalFromPicker(_ terminalID: MobileTerminalPreview.ID) {
        dismissTerminalKeyboardForChrome()
        isTerminalPickerPresented = false
        selectedTerminalID = terminalID
    }

    private func dismissTerminalKeyboardForChrome() {
        UIApplication.shared.dismissMobileKeyboard()
    }
}
