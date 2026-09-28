import CmuxTerminalSharing
import CmuxTerminalSizing
import SwiftUI
import UniformTypeIdentifiers

/// The shared-terminal size panel: current size and why, the mode control,
/// a size map, one row per participant (counts switch, priority order,
/// disconnect) and "Disconnect Other Clients" with an inline confirmation.
/// Every control calls ``TerminalSharingStore``, the shared action path.
struct TerminalSizePanelView: View {
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
                content(snapshot)
            } else {
                Text(String(localized: "terminalSharing.panel.unavailable", defaultValue: "This terminal is not shared."))
                    .foregroundStyle(.secondary)
                    .padding(16)
            }
        }
        .frame(width: 380)
    }

    @ViewBuilder
    private func content(_ snapshot: TerminalSharingSnapshot) -> some View {
        let display = TerminalSharingDisplay(snapshot: snapshot)
        VStack(alignment: .leading, spacing: 0) {
            header(snapshot, display: display)
            Divider()
            modeSection(snapshot)
            Divider()
            participantList(snapshot, display: display)
            Divider()
            footer(snapshot)
        }
    }

    private func header(_ snapshot: TerminalSharingSnapshot, display: TerminalSharingDisplay) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "terminalSharing.panel.title", defaultValue: "Terminal Size"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(TerminalSharingDisplay.gridLabel(snapshot.state.size))
                .font(.system(size: 22, design: .monospaced))
                .monospacedDigit()
            Text(display.reasonSentence)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func modeSection(_ snapshot: TerminalSharingSnapshot) -> some View {
        let mode = snapshot.state.policy.mode
        return VStack(alignment: .leading, spacing: 10) {
            Picker(
                String(localized: "terminalSharing.panel.mode", defaultValue: "Sizing Mode"),
                selection: Binding(
                    get: { mode },
                    set: { store.setMode($0, surfaceID: surfaceID) }
                )
            ) {
                ForEach(TerminalSizingMode.allCases, id: \.self) { mode in
                    Text(TerminalSharingDisplay.modeTitle(mode)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(TerminalSharingDisplay.modeHelp(mode))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if mode == .fixed {
                fixedSizeEditor(snapshot)
            }
            TerminalSizeMapView(snapshot: snapshot)
                .frame(height: 110)
        }
        .padding(14)
    }

    private func fixedSizeEditor(_ snapshot: TerminalSharingSnapshot) -> some View {
        let fixed = snapshot.state.policy.fixed ?? snapshot.state.size
        return HStack(spacing: 8) {
            TextField(
                String(localized: "terminalSharing.panel.fixedColumns", defaultValue: "Columns"),
                text: $fixedColumns,
                prompt: Text("\(fixed.cols)")
            )
            .frame(width: 70)
            Text(verbatim: "×")
            TextField(
                String(localized: "terminalSharing.panel.fixedRows", defaultValue: "Rows"),
                text: $fixedRows,
                prompt: Text("\(fixed.rows)")
            )
            .frame(width: 70)
            Button(String(localized: "terminalSharing.panel.fixedApply", defaultValue: "Apply")) {
                let cols = Int(fixedColumns) ?? fixed.cols
                let rows = Int(fixedRows) ?? fixed.rows
                store.setFixedSize(
                    TerminalGridSize(cols: min(max(cols, 20), 500), rows: min(max(rows, 5), 200)),
                    surfaceID: surfaceID
                )
                fixedColumns = ""
                fixedRows = ""
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func orderedRows(_ snapshot: TerminalSharingSnapshot) -> [TerminalSizingParticipantState] {
        let rows = snapshot.state.participants
        guard snapshot.state.policy.mode == .priority else { return rows }
        let order = snapshot.state.policy.priority
        return rows.sorted { lhs, rhs in
            let l = order.firstIndex(of: lhs.priorityKey) ?? Int.max
            let r = order.firstIndex(of: rhs.priorityKey) ?? Int.max
            return l < r
        }
    }

    private func participantList(_ snapshot: TerminalSharingSnapshot, display: TerminalSharingDisplay) -> some View {
        let rows = orderedRows(snapshot)
        let isPriority = snapshot.state.policy.mode == .priority
        return VStack(spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                TerminalSizeParticipantRow(
                    row: row,
                    label: display.label(for: row.participant),
                    isSelf: row.id == snapshot.selfParticipantID,
                    setsSize: snapshot.state.owners.contains(row.id),
                    priorityIndex: isPriority ? index + 1 : nil,
                    onCountsChange: { counts in
                        store.setCountsOverride(counts ? nil : false, participantID: row.id, surfaceID: surfaceID)
                        if counts, store.snapshot(for: surfaceID)?.state.participant(row.id)?.counts == false {
                            store.setCountsOverride(true, participantID: row.id, surfaceID: surfaceID)
                        }
                    },
                    onMoveUp: isPriority && index > 0 ? { movePriority(rows, from: index, to: index - 1) } : nil,
                    onDisconnect: row.id == snapshot.selfParticipantID ? nil : {
                        store.disconnect(participantID: row.id, surfaceID: surfaceID)
                    }
                )
                .onDrag {
                    NSItemProvider(object: row.priorityKey as NSString)
                }
                .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
                    guard isPriority, let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                        guard let key = object as? String else { return }
                        Task { @MainActor in
                            guard let from = rows.firstIndex(where: { $0.priorityKey == key }) else { return }
                            movePriority(rows, from: from, to: index)
                        }
                    }
                    return true
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private func movePriority(_ rows: [TerminalSizingParticipantState], from: Int, to: Int) {
        guard from != to, rows.indices.contains(from), rows.indices.contains(to) else { return }
        var keys = rows.map(\.priorityKey)
        let key = keys.remove(at: from)
        keys.insert(key, at: to)
        var seen = Set<String>()
        store.setPriority(keys.filter { seen.insert($0).inserted }, surfaceID: surfaceID)
    }

    private func footer(_ snapshot: TerminalSharingSnapshot) -> some View {
        HStack(spacing: 8) {
            if confirmingDisconnectOthers {
                Text(String(localized: "terminalSharing.panel.disconnectOthers.confirm", defaultValue: "Disconnect all other clients?"))
                    .font(.callout)
                Button(String(localized: "terminalSharing.panel.disconnectOthers.confirmButton", defaultValue: "Disconnect"), role: .destructive) {
                    store.disconnectOthers(surfaceID: surfaceID)
                    confirmingDisconnectOthers = false
                }
                Button(String(localized: "terminalSharing.panel.cancel", defaultValue: "Cancel")) {
                    confirmingDisconnectOthers = false
                }
            } else {
                Button(String(localized: "terminalSharing.panel.disconnectOthers", defaultValue: "Disconnect Other Clients…")) {
                    confirmingDisconnectOthers = true
                }
                .buttonStyle(.link)
                .disabled(snapshot.otherParticipantIDs.isEmpty)
                Spacer()
                Button(String(localized: "terminalSharing.panel.sizeToMe", defaultValue: "Size to My Window")) {
                    store.sizeToMe(surfaceID: surfaceID)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(snapshot.selfParticipant == nil)
            }
        }
        .padding(14)
    }
}
