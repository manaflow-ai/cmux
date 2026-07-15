import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation
import SwiftUI

struct TerminalHierarchyPaneSection: View {
    let pane: TerminalHierarchyPaneSnapshot
    let closeEnabled: Bool
    let canReorder: Bool
    let select: (TerminalHierarchyRowSnapshot) -> Void
    let requestClose: (TerminalHierarchyRowSnapshot) -> Void
    let reorderAction: (_ rowIndex: Int, _ destination: Int) -> (() -> Void)?
    let move: (_ source: IndexSet, _ destination: Int) -> Void

    var body: some View {
        Section {
            if pane.rows.isEmpty {
                Text(L10n.string(
                    "mobile.terminal.hierarchy.emptyPane",
                    defaultValue: "No terminals in this pane"
                ))
                .foregroundStyle(.secondary)
            } else {
                ForEach(Array(pane.rows.enumerated()), id: \.element.id) { rowIndex, row in
                    TerminalHierarchyRow(
                        snapshot: row,
                        select: { select(row) },
                        requestClose: { requestClose(row) },
                        closeEnabled: closeEnabled,
                        moveEarlier: reorderAction(rowIndex, rowIndex - 1),
                        moveLater: reorderAction(rowIndex, rowIndex + 2)
                    )
                }
                .onMove(perform: canReorder ? move : nil)
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
}
