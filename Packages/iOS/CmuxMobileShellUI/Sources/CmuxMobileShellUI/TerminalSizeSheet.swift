#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxTerminalSizing
import SwiftUI

/// The size panel for one shared terminal: the grid and its owner, the size
/// mode, the connected participants, and "Disconnect Others".
struct TerminalSizeSheet: View {
    let store: CMUXMobileShellStore
    let surfaceID: String

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingDisconnectOthers = false
    @State private var actionFailed = false
    @State private var fixedColumns = 80
    @State private var fixedRows = 24
    @FocusState private var fixedFieldFocused: Bool

    private static let columnRange = 20...300
    private static let rowRange = 5...120

    var body: some View {
        NavigationStack {
            Group {
                if let presentation = store.terminalSizingPresentation(for: surfaceID) {
                    list(presentation)
                        .toolbar { toolbar(presentation) }
                } else {
                    ProgressView()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(TerminalSizingText.done()) { dismiss() }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ presentation: MobileTerminalSizingPresentation) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text(TerminalSizingText.gridSize(presentation.grid))
                    .font(.headline)
                    .monospacedDigit()
                Text(TerminalSizingText.owner(presentation.ownerLabel))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
        if presentation.policy.mode == .priority {
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
            }
        }
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button(TerminalSizingText.done()) { fixedFieldFocused = false }
        }
    }

    private func list(_ presentation: MobileTerminalSizingPresentation) -> some View {
        List {
            Section {
                Picker(TerminalSizingText.sizePicker(), selection: modeBinding(presentation)) {
                    ForEach(TerminalSizingMode.allCases, id: \.self) { mode in
                        Text(TerminalSizingText.modeName(mode)).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                if presentation.policy.mode == .fixed {
                    fixedSizeRow(presentation)
                }
            } footer: {
                if actionFailed {
                    Text(TerminalSizingText.changeFailed())
                        .foregroundStyle(.red)
                }
            }

            Section(TerminalSizingText.participants()) {
                ForEach(orderedRows(presentation), id: \.id) { row in
                    participantRow(row, presentation: presentation)
                }
                .onMove(perform: presentation.policy.mode == .priority
                    ? { source, destination in movePriority(presentation, from: source, to: destination) }
                    : nil)
            }

            if !presentation.otherParticipants.isEmpty {
                Section {
                    Button(TerminalSizingText.disconnectOthers(), role: .destructive) {
                        isConfirmingDisconnectOthers = true
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("MobileTerminalSizingDisconnectOthers")
                    .confirmationDialog(
                        TerminalSizingText.disconnectOthersConfirm(),
                        isPresented: $isConfirmingDisconnectOthers,
                        titleVisibility: .visible
                    ) {
                        Button(TerminalSizingText.disconnectOthers(), role: .destructive) {
                            run { await store.disconnectOtherTerminalParticipants(surfaceID: surfaceID) }
                        }
                        .accessibilityIdentifier("MobileTerminalSizingDisconnectOthersConfirm")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            let fixed = presentation.policy.fixed ?? presentation.grid
            fixedColumns = fixed.cols
            fixedRows = fixed.rows
        }
        .onChange(of: fixedFieldFocused) { _, focused in
            if !focused { applyFixed(presentation) }
        }
    }

    // MARK: Fixed size

    private func fixedSizeRow(_ presentation: MobileTerminalSizingPresentation) -> some View {
        LabeledContent(TerminalSizingText.fixedSize()) {
            HStack(spacing: 6) {
                TextField(TerminalSizingText.columns(), value: $fixedColumns, format: .number)
                    .accessibilityLabel(TerminalSizingText.columns())
                    .frame(width: 52)
                Text(verbatim: "×")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(TerminalSizingText.rows(), value: $fixedRows, format: .number)
                    .accessibilityLabel(TerminalSizingText.rows())
                    .frame(width: 44)
            }
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .focused($fixedFieldFocused)
        }
    }

    private func applyFixed(_ presentation: MobileTerminalSizingPresentation) {
        fixedColumns = min(max(fixedColumns, Self.columnRange.lowerBound), Self.columnRange.upperBound)
        fixedRows = min(max(fixedRows, Self.rowRange.lowerBound), Self.rowRange.upperBound)
        guard presentation.policy.mode == .fixed else { return }
        var policy = presentation.policy
        policy.fixed = TerminalGridSize(cols: fixedColumns, rows: fixedRows)
        guard policy != presentation.policy else { return }
        run { await store.setTerminalSizePolicy(policy, surfaceID: surfaceID) }
    }

    // MARK: Participant rows

    private func allRows(_ presentation: MobileTerminalSizingPresentation) -> [TerminalSizingParticipantState] {
        (presentation.selfParticipant.map { [$0] } ?? []) + presentation.otherParticipants
    }

    /// In priority mode, rows follow the policy's priority keys (unranked rows
    /// after, in host order). Otherwise this phone first, then host order.
    private func orderedRows(
        _ presentation: MobileTerminalSizingPresentation
    ) -> [TerminalSizingParticipantState] {
        let rows = allRows(presentation)
        guard presentation.policy.mode == .priority else { return rows }
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

    private func participantRow(
        _ row: TerminalSizingParticipantState,
        presentation: MobileTerminalSizingPresentation
    ) -> some View {
        let isSelf = row.id == presentation.selfParticipant?.id
        let participant = row.participant
        let title = TerminalSizingText.participantTitle(participant, isSelf: isSelf)
        let status = TerminalSizingText.rowStatus(presentation.rowStatus(for: row))
        return HStack(spacing: 12) {
            TerminalSizingAvatar(participant: participant, isOwner: presentation.ownerIDs == [row.id])
                .opacity(row.counts ? 1 : 0.55)
            Text(title)
                .lineLimit(1)
                .foregroundStyle(row.counts ? .primary : .secondary)
            Spacer(minLength: 8)
            if let status {
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(isSelf ? "MobileTerminalSizingSelfRow" : "MobileTerminalSizingParticipantRow")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isSelf {
                Button(TerminalSizingText.disconnect(), role: .destructive) {
                    run { await store.disconnectTerminalParticipant(row.id, surfaceID: surfaceID) }
                }
            }
        }
        .contextMenu {
            if isSelf {
                // The Mac RPC sets the counts override for this phone only.
                Toggle(TerminalSizingText.countsToggle(), isOn: countsBinding(row))
            } else {
                Button(role: .destructive) {
                    run { await store.disconnectTerminalParticipant(row.id, surfaceID: surfaceID) }
                } label: {
                    Label(TerminalSizingText.disconnect(), systemImage: "xmark.circle")
                }
            }
        }
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
                    fixedColumns = presentation.grid.cols
                    fixedRows = presentation.grid.rows
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

    private func movePriority(
        _ presentation: MobileTerminalSizingPresentation,
        from source: IndexSet,
        to destination: Int
    ) {
        var keys = orderedRows(presentation).map(\.priorityKey)
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

/// A participant's avatar: the initial of their name, or their device glyph,
/// on a neutral grey fill. The owner gets a thin neutral ring.
private struct TerminalSizingAvatar: View {
    let participant: TerminalSizingParticipant
    let isOwner: Bool

    var body: some View {
        Circle()
            .fill(Color(.tertiarySystemFill))
            .frame(width: 28, height: 28)
            .overlay {
                if let initial = MobileTerminalSizingPresentation.givenName(participant.displayName)?.first {
                    Text(String(initial).uppercased())
                        .font(.footnote.weight(.semibold))
                } else {
                    Image(systemName: symbol)
                        .font(.caption.weight(.semibold))
                }
            }
            .foregroundStyle(.secondary)
            .overlay {
                if isOwner {
                    Circle()
                        .inset(by: -2)
                        .stroke(Color(.label).opacity(0.5), lineWidth: 1)
                }
            }
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch participant.deviceKind {
        case .mac: "laptopcomputer"
        case .iphone: "iphone"
        case .ipad: "ipad"
        case .tui: "terminal"
        case .browser: "globe"
        case .unknown: "person.fill"
        }
    }
}
#endif
