import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
#if canImport(UIKit)
@preconcurrency import UIKit
#endif

struct TerminalHierarchySheet: View {
    let snapshot: TerminalHierarchySnapshot
    let createTerminal: () -> Void
    let selectTerminal: (MobileTerminalPreview.ID) -> Void
    let reorderTerminal: (MobileTerminalReorderIntent) async -> Result<Void, MobileWorkspaceMutationFailure>
    let closeTerminal: (MobileTerminalPreview.ID, Bool) async -> Result<Void, MobileWorkspaceMutationFailure>

    @Environment(\.dismiss) private var dismiss
    @State private var pendingClose: TerminalHierarchyRowSnapshot?
    @State private var mutationFailed = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent(
                        L10n.string("mobile.terminal.hierarchy.workspace", defaultValue: "Workspace"),
                        value: snapshot.workspaceName
                    )
                    .accessibilityIdentifier("MobileTerminalHierarchyWorkspace")
                    if snapshot.connectionStatus != .connected {
                        Label(
                            connectionLabel,
                            systemImage: snapshot.connectionStatus == .reconnecting
                                ? "arrow.trianglehead.2.clockwise.rotate.90"
                                : "wifi.slash"
                        )
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("MobileTerminalHierarchyConnection")
                    }
                }
                if snapshot.panes.isEmpty {
                    emptyState
                } else {
                    ForEach(snapshot.panes) { pane in
                        terminalSection(pane)
                    }
                }
            }
            .navigationTitle(L10n.string("mobile.terminal.hierarchy.title", defaultValue: "Terminals"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { hierarchyToolbar }
            .confirmationDialog(
                L10n.string("mobile.terminal.hierarchy.closeTitle", defaultValue: "Close Terminal?"),
                isPresented: Binding(
                    get: { pendingClose != nil },
                    set: { if !$0 { pendingClose = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(
                    L10n.string("mobile.terminal.hierarchy.closeAction", defaultValue: "Close Terminal"),
                    role: .destructive,
                    action: confirmPendingClose
                )
                Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel"), role: .cancel) {
                    pendingClose = nil
                }
            } message: {
                Text(closeConsequence)
            }
            .alert(
                L10n.string("mobile.terminal.hierarchy.errorTitle", defaultValue: "Couldn't Update Terminals"),
                isPresented: $mutationFailed
            ) {
                Button(L10n.string("mobile.common.ok", defaultValue: "OK"), role: .cancel) {}
            } message: {
                Text(
                    L10n.string(
                        "mobile.terminal.hierarchy.errorMessage",
                        defaultValue: "The Mac kept the previous terminal state. Check the connection and try again."
                    )
                )
            }
        }
        .accessibilityIdentifier("MobileTerminalHierarchySheet")
    }

    private var emptyState: some View {
        ContentUnavailableView(
            L10n.string("mobile.terminal.hierarchy.emptyTitle", defaultValue: "No Terminals"),
            systemImage: "terminal",
            description: Text(
                L10n.string(
                    "mobile.terminal.hierarchy.emptyMessage",
                    defaultValue: "Create a terminal in the focused pane to get started."
                )
            )
        )
        .accessibilityIdentifier("MobileTerminalHierarchyEmpty")
    }

    @ViewBuilder
    private func terminalSection(_ pane: TerminalHierarchyPaneSnapshot) -> some View {
        Section {
            if pane.rows.isEmpty {
                Text(L10n.string("mobile.terminal.hierarchy.emptyPane", defaultValue: "No terminals in this pane"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(pane.rows) { row in
                    TerminalHierarchyRow(
                        snapshot: row,
                        select: { select(row) },
                        requestClose: { pendingClose = row }
                    )
                }
                .onMove(perform: snapshot.canReorder ? { source, destination in
                    move(source: source, destination: destination, in: pane)
                } : nil)
            }
        } header: {
            HStack(spacing: 6) {
                Text(
                    String(
                        format: L10n.string(
                            "mobile.terminal.hierarchy.paneTitle",
                            defaultValue: "Pane %d"
                        ),
                        pane.spatialIndex + 1
                    )
                )
                if pane.isFocused {
                    Label(
                        L10n.string("mobile.terminal.hierarchy.focusedPane", defaultValue: "Focused"),
                        systemImage: "scope"
                    )
                    .labelStyle(.titleAndIcon)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("MobileTerminalHierarchyPane-\(pane.id.rawValue)")
        }
    }

    @ToolbarContentBuilder
    private var hierarchyToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(L10n.string("mobile.common.done", defaultValue: "Done")) {
                dismiss()
            }
            .accessibilityIdentifier("MobileTerminalHierarchyDone")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if snapshot.canReorder, snapshot.panes.contains(where: { $0.rows.count > 1 }) {
                EditButton()
                    .accessibilityIdentifier("MobileTerminalHierarchyEdit")
            }
            Button(action: createAndAnnounce) {
                Label(
                    L10n.string("mobile.terminal.new", defaultValue: "New Terminal"),
                    systemImage: "plus"
                )
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(snapshot.connectionStatus != .connected)
            .accessibilityIdentifier("MobileTerminalHierarchyNewTerminal")
        }
    }

    private var closeConsequence: String {
        guard pendingClose?.requiresCloseConfirmation == true else {
            return L10n.string(
                "mobile.terminal.hierarchy.closeMessage",
                defaultValue: "The terminal will close and its position will be removed from this pane."
            )
        }
        return L10n.string(
            "mobile.terminal.hierarchy.closeRunningMessage",
            defaultValue: "This terminal is running a process. Closing it ends that process and cannot be undone."
        )
    }

    private var connectionLabel: String {
        snapshot.connectionStatus == .reconnecting
            ? L10n.string("mobile.terminal.hierarchy.reconnecting", defaultValue: "Reconnecting…")
            : L10n.string("mobile.terminal.hierarchy.disconnected", defaultValue: "Mac Disconnected")
    }

    private func select(_ row: TerminalHierarchyRowSnapshot) {
        selectTerminal(row.id)
        announce(
            String(
                format: L10n.string(
                    "mobile.terminal.hierarchy.switchedAnnouncement",
                    defaultValue: "Switched to %@"
                ),
                row.title
            )
        )
        dismiss()
    }

    private func createAndAnnounce() {
        createTerminal()
        announce(L10n.string("mobile.terminal.hierarchy.createdAnnouncement", defaultValue: "Creating terminal"))
    }

    private func move(
        source: IndexSet,
        destination: Int,
        in pane: TerminalHierarchyPaneSnapshot
    ) {
        guard source.count == 1,
              let sourceIndex = source.first,
              pane.rows.indices.contains(sourceIndex),
              let intent = MobileTerminalReorderIntent(
                  terminalID: pane.rows[sourceIndex].id,
                  sourceIndex: sourceIndex,
                  destinationIndex: destination,
                  pane: pane.pane
              ) else {
            mutationFailed = true
            return
        }
        Task { @MainActor in
            let result = await reorderTerminal(intent)
            guard case .success = result else {
                mutationFailed = true
                return
            }
            announce(L10n.string("mobile.terminal.hierarchy.reorderedAnnouncement", defaultValue: "Terminal order updated"))
        }
    }

    private func confirmPendingClose() {
        guard let pendingClose else { return }
        self.pendingClose = nil
        Task { @MainActor in
            let result = await closeTerminal(pendingClose.id, true)
            guard case .success = result else {
                mutationFailed = true
                return
            }
            announce(L10n.string("mobile.terminal.hierarchy.closedAnnouncement", defaultValue: "Terminal closed"))
        }
    }

    private func announce(_ message: String) {
        #if canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: message)
        #endif
    }
}
