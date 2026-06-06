import CmuxAuthRuntime
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
    @State private var isTerminalPickerPresented = false
    #if canImport(UIKit)
    @State private var diagnosticsReport: MobileDiagnosticsReport?
    @State private var isBuildingDiagnostics = false
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
            terminalPickerContent
        }
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
            #endif
        }
        .frame(minWidth: 240, maxWidth: 320, alignment: .leading)
        .presentationCompactAdaptation(.popover)
        #if canImport(UIKit)
        // Build the report once when the picker opens so both the Copy action and
        // the synchronous-item `ShareLink` can use it. Rebuilt each open so the
        // snapshot is fresh.
        .task {
            await prepareDiagnosticsReport()
        }
        #endif
    }

    #if canImport(UIKit)
    /// Copies the assembled, scrubbed diagnostics report to the clipboard.
    @ViewBuilder
    private var diagnosticsCopyButton: some View {
        Button(action: copyDiagnosticsToPasteboard) {
            Label(
                L10n.string("mobile.diagnostics.copy", defaultValue: "Copy Diagnostics"),
                systemImage: "doc.on.clipboard"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(diagnosticsReport == nil)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // Preserve the historical accessibility id so existing automation that
        // taps the debug-log export keeps working.
        .accessibilityIdentifier("MobileCopyDebugLogsMenuItem")
    }

    /// Shares the assembled, scrubbed diagnostics report as a `.txt` file.
    ///
    /// `ShareLink` needs the shared item synchronously, so it only renders once
    /// the temp file has been built; until then a disabled placeholder shows a
    /// progress state.
    @ViewBuilder
    private var diagnosticsShareButton: some View {
        if let report = diagnosticsReport {
            ShareLink(
                item: report.fileURL,
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
            Label(
                L10n.string("mobile.diagnostics.preparing", defaultValue: "Preparing Diagnostics…"),
                systemImage: "square.and.arrow.up"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityIdentifier("MobileShareDiagnosticsMenuItem")
        }
    }
    #endif

    #if canImport(UIKit)
    /// The shell's live runtime state, mapped into the decoupled diagnostics
    /// snapshot the report builder consumes.
    private var diagnosticsLiveState: MobileDiagnosticsLiveState {
        let host = store.connectedHostName.isEmpty ? nil : store.connectedHostName
        return MobileDiagnosticsLiveState(
            connectionState: store.connectionState == .connected ? "connected" : "disconnected",
            isSignedIn: store.isSignedIn,
            isAuthenticated: authManager.isAuthenticated,
            lastAuthError: authManager.lastAuthErrorDescription,
            connectedHostName: host,
            pairedMacName: host,
            pairedMacDeviceID: nil,
            connectionError: store.connectionError
        )
    }

    /// Builds the diagnostics report (in-process log + OS log + live state +
    /// visible terminal, then scrubbed) and writes the shareable temp file.
    ///
    /// Runs when the picker opens so both Copy and `ShareLink` have a ready item.
    private func prepareDiagnosticsReport() async {
        guard !isBuildingDiagnostics else { return }
        isBuildingDiagnostics = true
        defer { isBuildingDiagnostics = false }

        let terminalText = GhosttySurfaceView.visibleTerminalSnapshot()
        let liveState = diagnosticsLiveState
        let builder = MobileDiagnosticsReportBuilder(sink: MobileDebugLog.shared.sink)
        let report = await builder.buildReport(
            liveState: liveState,
            terminalSnapshot: terminalText
        )
        diagnosticsReport = report
    }

    /// Copies the prepared diagnostics text to the system pasteboard.
    private func copyDiagnosticsToPasteboard() {
        guard let report = diagnosticsReport else { return }
        isTerminalPickerPresented = false
        UIPasteboard.general.string = report.text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
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
