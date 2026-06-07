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
    @State private var diagnosticsSessionID = UUID()
    @State private var diagnosticsPreparationTask: Task<MobileDiagnosticsReport, Error>?
    @State private var diagnosticsActionTask: Task<Void, Never>?
    @State private var diagnosticsShareSheetItem: MobileDiagnosticsActivityItem?
    @State private var pendingDiagnosticsShareSheetItem: MobileDiagnosticsActivityItem?
    @State private var isPreparingDiagnostics = false
    @State private var diagnosticsFailureAlert: MobileDiagnosticsFailureAlert?
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
        #if canImport(UIKit)
        .sheet(item: $diagnosticsShareSheetItem) { item in
            MobileDiagnosticsActivityView(item: item)
        }
        .sheet(isPresented: $isFeedbackComposerPresented) {
            MobileFeedbackComposerSheet(
                initialEmail: feedbackInitialEmail,
                initialDiagnosticsReport: diagnosticsReport,
                buildDiagnosticsReport: buildDiagnosticsReport,
                client: feedbackClient
            )
            .presentationDetents([.large])
        }
        .alert(item: $diagnosticsFailureAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text(L10n.string("common.ok", defaultValue: "OK")))
            )
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
            resetDiagnosticsForNewPickerSession()
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
            .onDisappear(perform: terminalPickerDidDisappear)
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
        Button(action: startCopyDiagnosticsToPasteboard) {
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
            Button(action: startDiagnosticsShare) {
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
        .disabled(isPreparingDiagnostics)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityIdentifier("MobileSendFeedbackMenuItem")
    }
    #endif

    #if canImport(UIKit)
    private func diagnosticsActionLabel(title: String, systemImage: String) -> Label<Text, Image> {
        Label(title, systemImage: systemImage)
    }

    @MainActor
    private func resetDiagnosticsForNewPickerSession() {
        diagnosticsSessionID = UUID()
        diagnosticsActionTask?.cancel()
        diagnosticsActionTask = nil
        diagnosticsPreparationTask?.cancel()
        diagnosticsPreparationTask = nil
        diagnosticsReport = nil
        diagnosticsShareSheetItem = nil
        pendingDiagnosticsShareSheetItem = nil
        diagnosticsFailureAlert = nil
        isPreparingDiagnostics = false
    }

    @MainActor
    private func cancelDiagnosticsWorkForCurrentSession() {
        diagnosticsActionTask?.cancel()
        diagnosticsActionTask = nil
        diagnosticsPreparationTask?.cancel()
        diagnosticsPreparationTask = nil
        isPreparingDiagnostics = false
    }

    /// The shell's live runtime state, mapped into the decoupled diagnostics
    /// snapshot the report builder consumes.
    private var diagnosticsLiveState: MobileDiagnosticsLiveState {
        let host = store.connectedHostName.isEmpty ? nil : store.connectedHostName
        let activeTicket = store.activeTicket
        let activePairedMac = store.activePairedMac
        let persistedActivePairedMac = store.pairedMacs.first { $0.isActive }
        return MobileDiagnosticsLiveState(
            connectionState: diagnosticsConnectionState,
            isSignedIn: store.isSignedIn,
            isAuthenticated: authManager.isAuthenticated,
            lastAuthError: authManager.lastAuthErrorDescription,
            connectedHostName: host,
            pairedMacName: activeTicket?.macDisplayName
                ?? activePairedMac?.displayName
                ?? persistedActivePairedMac?.displayName
                ?? activeTicket?.macDeviceID
                ?? activePairedMac?.macDeviceID
                ?? persistedActivePairedMac?.macDeviceID,
            pairedMacDeviceID: activeTicket?.macDeviceID
                ?? activePairedMac?.macDeviceID
                ?? persistedActivePairedMac?.macDeviceID,
            connectionError: store.connectionError
        )
    }

    private var feedbackInitialEmail: String? {
        guard authManager.isAuthenticated,
              let email = authManager.currentUser?.primaryEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
              email.isEmpty == false else {
            return nil
        }
        return email
    }

    private var diagnosticsConnectionState: String {
        switch connectionStatus {
        case .connected:
            return "connected"
        case .reconnecting:
            return "reconnecting"
        case .unavailable:
            return "unavailable"
        }
    }

    /// Builds the report after the user chooses a diagnostics action, so the
    /// terminal picker itself stays a cheap navigation control.
    @MainActor
    private func prepareDiagnosticsReport(sessionID: UUID, cacheResult: Bool) async -> MobileDiagnosticsReport? {
        guard diagnosticsSessionID == sessionID else { return nil }
        if let diagnosticsPreparationTask {
            do {
                let report = try await diagnosticsPreparationTask.value
                guard diagnosticsSessionID == sessionID, !Task.isCancelled else { return nil }
                if cacheResult {
                    diagnosticsReport = report
                }
                self.diagnosticsPreparationTask = nil
                isPreparingDiagnostics = false
                return report
            } catch {
                guard diagnosticsSessionID == sessionID else { return nil }
                self.diagnosticsPreparationTask = nil
                isPreparingDiagnostics = false
                return nil
            }
        }

        isPreparingDiagnostics = true
        let task = Task { @MainActor in
            try Task.checkCancellation()
            let report = await buildDiagnosticsReport()
            try Task.checkCancellation()
            return report
        }
        diagnosticsPreparationTask = task
        do {
            let report = try await task.value
            guard diagnosticsSessionID == sessionID, !Task.isCancelled else { return nil }
            if cacheResult {
                diagnosticsReport = report
            }
            diagnosticsPreparationTask = nil
            isPreparingDiagnostics = false
            return report
        } catch {
            guard diagnosticsSessionID == sessionID else { return nil }
            diagnosticsPreparationTask = nil
            isPreparingDiagnostics = false
            return nil
        }
    }

    @MainActor
    private func startDiagnosticsShare() {
        let sessionID = diagnosticsSessionID
        diagnosticsActionTask?.cancel()
        diagnosticsActionTask = Task { @MainActor in
            await prepareAndPresentDiagnosticsShareSheet(sessionID: sessionID)
        }
    }

    @MainActor
    private func prepareAndPresentDiagnosticsShareSheet(sessionID: UUID) async {
        guard let report = await prepareDiagnosticsReport(sessionID: sessionID, cacheResult: true) else {
            showDiagnosticsPreparationFailureIfCurrent(sessionID: sessionID)
            return
        }
        guard diagnosticsSessionID == sessionID, !Task.isCancelled else { return }
        let item = MobileDiagnosticsActivityItem(text: report.text)
        if isTerminalPickerPresented {
            pendingDiagnosticsShareSheetItem = item
            isTerminalPickerPresented = false
        } else {
            diagnosticsShareSheetItem = item
        }
        diagnosticsActionTask = nil
    }

    /// Builds the diagnostics report (in-process log + OS log + live state +
    /// visible terminal, then scrubbed).
    @MainActor
    private func buildDiagnosticsReport() async -> MobileDiagnosticsReport {
        let terminalText = GhosttySurfaceView.visibleTerminalSnapshot()
        let liveState = diagnosticsLiveState
        let immediateEventLines = await store.diagnosticsImmediateEventLinesForReport()
        let environment = MobileDiagnosticsEnvironment.current()
        let builder = MobileDiagnosticsReportBuilder(
            environment: environment,
            sink: MobileDebugLog.shared.sink
        )
        return await builder.buildReport(
            liveState: liveState,
            terminalSnapshot: terminalText,
            immediateEventLines: immediateEventLines,
            osLogNotBefore: store.diagnosticsOSLogBoundaryDate
        )
    }

    /// Copies the prepared diagnostics text to the system pasteboard.
    @MainActor
    private func startCopyDiagnosticsToPasteboard() {
        let sessionID = diagnosticsSessionID
        diagnosticsActionTask?.cancel()
        diagnosticsActionTask = Task { @MainActor in
            await copyDiagnosticsToPasteboard(sessionID: sessionID)
        }
    }

    /// Copies the prepared diagnostics text to the system pasteboard.
    @MainActor
    private func copyDiagnosticsToPasteboard(sessionID: UUID) async {
        guard let report = await prepareDiagnosticsReport(sessionID: sessionID, cacheResult: false) else {
            showDiagnosticsPreparationFailureIfCurrent(sessionID: sessionID)
            return
        }
        guard diagnosticsSessionID == sessionID, !Task.isCancelled else { return }
        isTerminalPickerPresented = false
        UIPasteboard.general.string = report.text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        diagnosticsActionTask = nil
    }

    /// Presents the mobile feedback form with the current diagnostics report.
    private func presentFeedbackComposer() {
        shouldPresentFeedbackAfterPickerDismisses = true
        isTerminalPickerPresented = false
    }

    private func terminalPickerDidDisappear() {
        guard !presentPendingPostPickerSheetIfNeeded() else { return }
        cancelDiagnosticsWorkForCurrentSession()
    }

    @MainActor
    private func showDiagnosticsPreparationFailureIfCurrent(sessionID: UUID) {
        guard diagnosticsSessionID == sessionID, !Task.isCancelled else { return }
        diagnosticsActionTask = nil
        diagnosticsFailureAlert = MobileDiagnosticsFailureAlert()
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    @discardableResult
    private func presentPendingPostPickerSheetIfNeeded() -> Bool {
        if let pendingDiagnosticsShareSheetItem {
            self.pendingDiagnosticsShareSheetItem = nil
            diagnosticsShareSheetItem = pendingDiagnosticsShareSheetItem
            return true
        }
        guard shouldPresentFeedbackAfterPickerDismisses else { return false }
        shouldPresentFeedbackAfterPickerDismisses = false
        isFeedbackComposerPresented = true
        return true
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
        store.selectTerminalFromChrome(terminalID)
        selectedTerminalID = terminalID
    }

    private func dismissTerminalKeyboardForChrome() {
        UIApplication.shared.dismissMobileKeyboard()
    }
}
