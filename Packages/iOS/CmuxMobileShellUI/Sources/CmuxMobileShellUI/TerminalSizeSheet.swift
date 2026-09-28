#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxTerminalSizing
import SwiftUI

/// The size panel for one shared terminal: current size and reason, the
/// sizing mode, every participant, and "Disconnect Other Clients".
struct TerminalSizeSheet: View {
    let store: CMUXMobileShellStore
    let surfaceID: String

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingDisconnectOthers = false
    @State private var actionFailed = false
    @State private var fixedColumns = 80
    @State private var fixedRows = 24

    var body: some View {
        NavigationStack {
            Group {
                if let presentation = store.terminalSizingPresentation(for: surfaceID) {
                    form(presentation)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(TerminalSizingText.sheetTitle())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(TerminalSizingText.done()) { dismiss() }
                }
            }
        }
    }

    private func form(_ presentation: MobileTerminalSizingPresentation) -> some View {
        Form {
            Section {
                LabeledContent(TerminalSizingText.currentSize()) {
                    Text(TerminalSizingText.gridSize(presentation.grid))
                        .monospacedDigit()
                }
                Text(TerminalSizingText.reason(presentation.reason))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if actionFailed {
                    Text(TerminalSizingText.changeFailed())
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Picker(TerminalSizingText.modePicker(), selection: modeBinding(presentation)) {
                    ForEach(TerminalSizingMode.allCases, id: \.self) { mode in
                        Text(TerminalSizingText.modeName(mode)).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                if presentation.policy.mode == .fixed {
                    Stepper(
                        TerminalSizingText.fixedColumns(fixedColumns),
                        value: $fixedColumns,
                        in: 20...300,
                        onEditingChanged: { editing in
                            if !editing { applyFixed(presentation) }
                        }
                    )
                    Stepper(
                        TerminalSizingText.fixedRows(fixedRows),
                        value: $fixedRows,
                        in: 5...120,
                        onEditingChanged: { editing in
                            if !editing { applyFixed(presentation) }
                        }
                    )
                }
            }

            Section {
                if presentation.policy.mode == .priority {
                    ForEach(priorityOrderedRows(presentation), id: \.id) { row in
                        participantRow(row, presentation: presentation)
                    }
                    .onMove { source, destination in
                        movePriority(presentation, from: source, to: destination)
                    }
                } else {
                    ForEach(allRows(presentation), id: \.id) { row in
                        participantRow(row, presentation: presentation)
                    }
                }
            } header: {
                Text(TerminalSizingText.participants())
            } footer: {
                if presentation.policy.mode == .priority {
                    Text(TerminalSizingText.priorityHint())
                }
            }
            .environment(\.editMode, .constant(presentation.policy.mode == .priority ? .active : .inactive))

            if !presentation.otherParticipants.isEmpty {
                Section {
                    if isConfirmingDisconnectOthers {
                        Text(TerminalSizingText.disconnectOthersConfirm())
                            .font(.footnote)
                        Button(TerminalSizingText.disconnect(), role: .destructive) {
                            isConfirmingDisconnectOthers = false
                            run { await store.disconnectOtherTerminalParticipants(surfaceID: surfaceID) }
                        }
                        .accessibilityIdentifier("MobileTerminalSizingDisconnectOthersConfirm")
                        Button(TerminalSizingText.cancel(), role: .cancel) {
                            isConfirmingDisconnectOthers = false
                        }
                    } else {
                        Button(TerminalSizingText.disconnectOthers(), role: .destructive) {
                            isConfirmingDisconnectOthers = true
                        }
                        .accessibilityIdentifier("MobileTerminalSizingDisconnectOthers")
                    }
                }
            }
        }
        .onAppear {
            let fixed = presentation.policy.fixed ?? presentation.grid
            fixedColumns = fixed.cols
            fixedRows = fixed.rows
        }
    }

    // MARK: Participant rows

    private func allRows(_ presentation: MobileTerminalSizingPresentation) -> [TerminalSizingParticipantState] {
        (presentation.selfParticipant.map { [$0] } ?? []) + presentation.otherParticipants
    }

    /// Rows ordered by the policy's priority keys; unranked rows follow in host order.
    private func priorityOrderedRows(
        _ presentation: MobileTerminalSizingPresentation
    ) -> [TerminalSizingParticipantState] {
        let rows = allRows(presentation)
        let rank = Dictionary(
            presentation.policy.priority.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return rows.enumerated().sorted { lhs, rhs in
            let l = rank[lhs.element.priorityKey] ?? Int.max
            let r = rank[rhs.element.priorityKey] ?? Int.max
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map(\.element)
    }

    @ViewBuilder
    private func participantRow(
        _ row: TerminalSizingParticipantState,
        presentation: MobileTerminalSizingPresentation
    ) -> some View {
        let isSelf = row.id == presentation.selfParticipant?.id
        let participant = row.participant
        let name = isSelf
            ? TerminalSizingText.thisDevice(participant.deviceKind)
            : (participant.displayName ?? TerminalSizingText.someone())
        let isOwner = presentation.ownerIDs.contains(row.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(MobileTerminalSizingParticipantColor(participant: participant)))
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.body)
                    Text(detailLine(participant))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                badges(row: row, isSelf: isSelf, isOwner: isOwner)
                if !isSelf {
                    Button(role: .destructive) {
                        run { await store.disconnectTerminalParticipant(row.id, surfaceID: surfaceID) }
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(TerminalSizingText.disconnectAccessibilityLabel(name))
                }
            }
            if isSelf {
                Toggle(TerminalSizingText.countsToggle(), isOn: countsBinding(row))
                    .font(.subheadline)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func detailLine(_ participant: TerminalSizingParticipant) -> String {
        let device = TerminalSizingText.deviceName(participant)
        guard let viewport = participant.viewport else { return device }
        return TerminalSizingText.joined(device, TerminalSizingText.gridSize(viewport))
    }

    @ViewBuilder
    private func badges(row: TerminalSizingParticipantState, isSelf: Bool, isOwner: Bool) -> some View {
        HStack(spacing: 4) {
            if isSelf {
                badge(TerminalSizingText.badgeYou(), tint: .secondary)
            }
            if isOwner {
                badge(TerminalSizingText.badgeSetsSize(), tint: .accentColor)
            } else if !row.counts {
                badge(TerminalSizingText.badgeViewer(), tint: .secondary)
            }
            if isSelf, store.terminalAllowsTraffic(surfaceID: surfaceID) == false {
                badge(TerminalSizingText.badgeDetached(), tint: .orange)
            }
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: Capsule())
    }

    // MARK: Actions

    private func modeBinding(_ presentation: MobileTerminalSizingPresentation) -> Binding<TerminalSizingMode> {
        Binding(
            get: { presentation.policy.mode },
            set: { mode in
                var policy = presentation.policy
                policy.mode = mode
                if mode == .fixed, policy.fixed == nil {
                    policy.fixed = presentation.grid
                }
                if mode == .priority, policy.priority.isEmpty {
                    policy.priority = allRows(presentation).map(\.priorityKey)
                }
                run { await store.setTerminalSizePolicy(policy, surfaceID: surfaceID) }
            }
        )
    }

    private func countsBinding(_ row: TerminalSizingParticipantState) -> Binding<Bool> {
        Binding(
            get: { row.counts },
            set: { counts in
                run { await store.setTerminalCountsOverride(counts, surfaceID: surfaceID) }
            }
        )
    }

    private func applyFixed(_ presentation: MobileTerminalSizingPresentation) {
        var policy = presentation.policy
        policy.fixed = TerminalGridSize(cols: fixedColumns, rows: fixedRows)
        guard policy != presentation.policy else { return }
        run { await store.setTerminalSizePolicy(policy, surfaceID: surfaceID) }
    }

    private func movePriority(
        _ presentation: MobileTerminalSizingPresentation,
        from source: IndexSet,
        to destination: Int
    ) {
        var keys = priorityOrderedRows(presentation).map(\.priorityKey)
        keys.move(fromOffsets: source, toOffset: destination)
        var seen = Set<String>()
        let ranked = keys.filter { seen.insert($0).inserted }
        // Keep ranked keys of participants that are not attached right now,
        // after the attached ones, so a reconnect finds its old slot.
        let detachedKeys = presentation.policy.priority.filter { !seen.contains($0) }
        var policy = presentation.policy
        policy.priority = ranked + detachedKeys
        run { await store.setTerminalSizePolicy(policy, surfaceID: surfaceID) }
    }

    private func run(_ action: @escaping @MainActor () async -> Bool) {
        actionFailed = false
        Task { @MainActor in
            let succeeded = await action()
            actionFailed = !succeeded
        }
    }
}
#endif
