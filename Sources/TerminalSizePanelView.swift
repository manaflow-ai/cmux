import CmuxTerminalSharing
import CmuxTerminalSizing
import SwiftUI

/// The shared-terminal size panel, anchored under the terminal's tab: the
/// grid and its owner, the sizing mode, one row per participant and
/// "Disconnect Others" with an inline confirmation. Every control calls
/// ``TerminalSharingStore``, the shared action path.
struct TerminalSizePanelView: View {
    static let width: CGFloat = 280

    let store: TerminalSharingStore
    let surfaceID: UUID
    @State var confirmingDisconnectOthers: Bool
    @State private var fixedColumns = ""
    @State private var fixedRows = ""

    init(store: TerminalSharingStore, surfaceID: UUID, confirmDisconnectOthers: Bool = false) {
        self.store = store
        self.surfaceID = surfaceID
        _confirmingDisconnectOthers = State(initialValue: confirmDisconnectOthers)
    }

    var body: some View {
        Group {
            if let snapshot = store.snapshot(for: surfaceID) {
                content(TerminalSharingDisplay(snapshot: snapshot))
            } else {
                Text(String(localized: "terminalSharing.panel.unavailable", defaultValue: "This terminal is not shared."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: Self.width, alignment: .leading)
        // Opaque, so pane content never shows through the popover.
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func content(_ display: TerminalSharingDisplay) -> some View {
        let presentation = display.presentation
        let snapshot = display.snapshot
        return VStack(alignment: .leading, spacing: 8) {
            header(presentation)
            modeRow(snapshot.state.policy.mode)
            if snapshot.state.policy.mode == .fixed {
                fixedSizeEditor(snapshot.state.policy.fixed ?? snapshot.state.size)
            }
            Divider()
            participantList(presentation)
            if presentation.canDisconnectOthers {
                Divider()
                footer
            }
        }
    }

    private func header(_ presentation: TerminalSharingPresentation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: TerminalSharingPresentation.gridLabel(presentation.state.size))
                .font(.headline.monospacedDigit())
            Spacer(minLength: 8)
            Text(presentation.ownerLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }

    private func modeRow(_ mode: TerminalSizingMode) -> some View {
        HStack(spacing: 8) {
            Text(String(localized: "terminalSharing.panel.sizeLabel", defaultValue: "Size"))
            Spacer(minLength: 8)
            Picker(
                String(localized: "terminalSharing.panel.sizeLabel", defaultValue: "Size"),
                selection: Binding(
                    get: { mode },
                    set: { _ = store.setMode($0, surfaceID: surfaceID) }
                )
            ) {
                ForEach(TerminalSizingMode.allCases, id: \.self) { mode in
                    Text(TerminalSharingDisplay.modeTitle(mode)).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }

    private func fixedSizeEditor(_ fixed: TerminalGridSize) -> some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            TextField(
                String(localized: "terminalSharing.panel.fixedColumns", defaultValue: "Columns"),
                text: $fixedColumns,
                prompt: Text(verbatim: "\(fixed.cols)")
            )
            .frame(width: 52)
            Text(verbatim: "×").foregroundStyle(.secondary)
            TextField(
                String(localized: "terminalSharing.panel.fixedRows", defaultValue: "Rows"),
                text: $fixedRows,
                prompt: Text(verbatim: "\(fixed.rows)")
            )
            .frame(width: 44)
        }
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
        .onSubmit { applyFixedSize(fixed) }
    }

    private func applyFixedSize(_ fixed: TerminalGridSize) {
        let cols = Int(fixedColumns.trimmingCharacters(in: .whitespaces)) ?? fixed.cols
        let rows = Int(fixedRows.trimmingCharacters(in: .whitespaces)) ?? fixed.rows
        _ = store.setFixedSize(
            TerminalGridSize(cols: min(max(cols, 20), 500), rows: min(max(rows, 5), 200)),
            surfaceID: surfaceID
        )
        fixedColumns = ""
        fixedRows = ""
    }

    private func participantList(_ presentation: TerminalSharingPresentation) -> some View {
        let rows = presentation.panelParticipants
        let isPriority = presentation.state.policy.mode == .priority
        let snapshot = presentation.snapshot
        return VStack(spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let isSelf = row.id == snapshot.selfParticipantID
                let rowView = TerminalSizeParticipantRow(
                    row: row,
                    initials: presentation.initials(for: row.participant),
                    label: presentation.participantLabel(for: row.participant),
                    isOwner: row.id == presentation.ownerID,
                    statusLabel: TerminalSharingDisplay.rowStatusLabel(presentation.rowStatus(for: row)),
                    showsDragHandle: isPriority,
                    onCountsChange: { setCounts($0, participantID: row.id) },
                    onDisconnect: isSelf ? nil : {
                        _ = store.disconnect(participantID: row.id, surfaceID: surfaceID)
                    }
                )
                if isPriority {
                    rowView
                        .draggable(row.priorityKey)
                        .dropDestination(for: String.self) { keys, _ in
                            guard let key = keys.first,
                                  let from = rows.firstIndex(where: { $0.priorityKey == key }) else { return false }
                            movePriority(rows, from: from, to: index)
                            return true
                        }
                } else {
                    rowView
                }
            }
        }
    }

    /// `true` clears any viewer override (automatic rule); if the automatic
    /// rule still excludes the participant, forces it to count.
    private func setCounts(_ counts: Bool, participantID: String) {
        _ = store.setCountsOverride(counts ? nil : false, participantID: participantID, surfaceID: surfaceID)
        if counts, store.snapshot(for: surfaceID)?.state.participant(participantID)?.counts == false {
            _ = store.setCountsOverride(true, participantID: participantID, surfaceID: surfaceID)
        }
    }

    private func movePriority(_ rows: [TerminalSizingParticipantState], from: Int, to: Int) {
        guard from != to, rows.indices.contains(from), rows.indices.contains(to) else { return }
        var keys = rows.map(\.priorityKey)
        let key = keys.remove(at: from)
        keys.insert(key, at: to)
        var seen = Set<String>()
        _ = store.setPriority(keys.filter { seen.insert($0).inserted }, surfaceID: surfaceID)
    }

    @ViewBuilder
    private var footer: some View {
        if confirmingDisconnectOthers {
            HStack(spacing: 8) {
                Text(String(localized: "terminalSharing.panel.disconnectOthers.confirm", defaultValue: "Disconnect all other clients?"))
                    .font(.callout)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(String(localized: "terminalSharing.panel.cancel", defaultValue: "Cancel")) {
                    confirmingDisconnectOthers = false
                }
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "terminalSharing.panel.disconnectOthers.confirmButton", defaultValue: "Disconnect"), role: .destructive) {
                    _ = store.disconnectOthers(surfaceID: surfaceID)
                    confirmingDisconnectOthers = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        } else {
            Button(String(localized: "terminalSharing.panel.disconnectOthersButton", defaultValue: "Disconnect Others")) {
                confirmingDisconnectOthers = true
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
        }
    }
}
