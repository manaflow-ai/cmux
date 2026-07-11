import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation
import SwiftUI
#if canImport(UIKit)
@preconcurrency import UIKit
#endif

struct TerminalHierarchySheet: View {
    let snapshot: TerminalHierarchySnapshot
    let createTerminal: () -> Void
    let selectTerminal: (MobileTerminalPreview.ID) -> Void
    let reorderGate: MobileTerminalReorderGate
    let reorderTerminal: (
        MobileTerminalReorderIntent,
        MobileTerminalReorderReservation
    ) async -> Result<Void, MobileWorkspaceMutationFailure>
    let closeTerminal: (MobileTerminalPreview.ID, Bool) async -> Result<Void, MobileWorkspaceMutationFailure>

    @Environment(\.dismiss) private var dismiss
    @State private var pendingClose: TerminalHierarchyRowSnapshot?
    @State private var closeConfirmationIncludesRunningProcess = false
    @State private var mutationFailed = false
    @State private var optimisticTerminalIDsByPane: [MobilePanePreview.ID: [MobileTerminalPreview.ID]] = [:]

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
                        terminalSection(presentedPane(pane))
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
                    set: { if !$0 { clearPendingClose() } }
                ),
                titleVisibility: .visible
            ) {
                Button(
                    L10n.string("mobile.terminal.hierarchy.closeAction", defaultValue: "Close Terminal"),
                    role: .destructive,
                    action: confirmPendingClose
                )
                Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel"), role: .cancel) {
                    clearPendingClose()
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
                ForEach(Array(pane.rows.enumerated()), id: \.element.id) { rowIndex, row in
                    TerminalHierarchyRow(
                        snapshot: row,
                        select: { select(row) },
                        requestClose: { requestClose(row) },
                        moveEarlier: reorderAction(
                            rowIndex: rowIndex,
                            destination: rowIndex - 1,
                            in: pane
                        ),
                        moveLater: reorderAction(
                            rowIndex: rowIndex,
                            destination: rowIndex + 2,
                            in: pane
                        )
                    )
                }
                .onMove(perform: snapshot.canReorder && !reorderGate.isActive ? { source, destination in
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
                        locale: Locale.current,
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
                    .disabled(reorderGate.isActive)
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
        pendingClose?.closeConsequence(
            requiresProcessConfirmation: closeConfirmationIncludesRunningProcess
        ) ?? ""
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
                locale: Locale.current,
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
              pane.rows.indices.contains(sourceIndex) else {
            mutationFailed = true
            return
        }
        if destination == sourceIndex || destination == sourceIndex + 1 {
            return
        }
        guard let intent = MobileTerminalReorderIntent(
                  terminalID: pane.rows[sourceIndex].id,
                  sourceIndex: sourceIndex,
                  destinationIndex: destination,
                  pane: pane.pane
              ) else {
            mutationFailed = true
            return
        }
        guard let reservation = reorderGate.reserve(
            workspaceID: snapshot.workspaceID,
            paneID: pane.id
        ) else { return }
        guard let optimisticOrder = intent.applying(to: pane.rows.map(\.id)) else {
            reorderGate.finish(reservation)
            mutationFailed = true
            return
        }
        optimisticTerminalIDsByPane[pane.id] = optimisticOrder
        Task { @MainActor in
            let result = await reorderTerminal(intent, reservation)
            guard case .success = result else {
                optimisticTerminalIDsByPane[pane.id] = nil
                mutationFailed = true
                return
            }
            optimisticTerminalIDsByPane[pane.id] = nil
            announce(L10n.string("mobile.terminal.hierarchy.reorderedAnnouncement", defaultValue: "Terminal order updated"))
        }
    }

    private func presentedPane(_ pane: TerminalHierarchyPaneSnapshot) -> TerminalHierarchyPaneSnapshot {
        guard let optimisticIDs = optimisticTerminalIDsByPane[pane.id] else { return pane }
        let rowsByID = Dictionary(uniqueKeysWithValues: pane.rows.map { ($0.id, $0) })
        return TerminalHierarchyPaneSnapshot(
            id: pane.id,
            spatialIndex: pane.spatialIndex,
            isFocused: pane.isFocused,
            rows: optimisticIDs.compactMap { rowsByID[$0] },
            pane: pane.pane
        )
    }

    private func reorderAction(
        rowIndex: Int?,
        destination: Int?,
        in pane: TerminalHierarchyPaneSnapshot
    ) -> (() -> Void)? {
        guard snapshot.canReorder,
              !reorderGate.isActive,
              let rowIndex,
              let destination,
              destination >= 0,
              destination <= pane.rows.count,
              destination != rowIndex,
              destination != rowIndex + 1 else {
            return nil
        }
        return { move(source: IndexSet(integer: rowIndex), destination: destination, in: pane) }
    }

    private func confirmPendingClose() {
        guard let pendingClose else { return }
        let confirmed = closeConfirmationIncludesRunningProcess
        clearPendingClose()
        Task { @MainActor in
            switch await closeTerminal(pendingClose.id, confirmed) {
            case .success:
                announce(L10n.string("mobile.terminal.hierarchy.closedAnnouncement", defaultValue: "Terminal closed"))
            case .failure(.confirmationRequired):
                self.pendingClose = pendingClose
                closeConfirmationIncludesRunningProcess = true
            case .failure:
                mutationFailed = true
            }
        }
    }

    private func requestClose(_ row: TerminalHierarchyRowSnapshot) {
        pendingClose = row
        closeConfirmationIncludesRunningProcess = row.requiresCloseConfirmation
    }

    private func clearPendingClose() {
        pendingClose = nil
        closeConfirmationIncludesRunningProcess = false
    }

    private func announce(_ message: String) {
        #if canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: message)
        #endif
    }
}
