#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileTerminalKit
import CmuxTerminalSizing
import SwiftUI

/// The size panel for one shared terminal: the grid and its owner, the size
/// mode, the connected participants, and "Disconnect Others".
struct TerminalSizeSheet: View {
    let store: CMUXMobileShellStore
    let surfaceID: String

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingDisconnectOthers = false
    /// The Mac row awaiting its disconnect confirmation.
    @State private var pendingMacDisconnect: TerminalSizingParticipantState?
    @State private var actionFailed = false
    @State private var fixedColumns = 80
    @State private var fixedRows = 24
    @State private var listEditMode: EditMode = .inactive
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
                Text(TerminalSizingText.modeDescription(presentation.policy.mode))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if presentation.policy.mode == .fixed {
                    fixedSizeRow(presentation)
                }
            } footer: {
                if actionFailed {
                    Text(TerminalSizingText.changeFailed())
                        .foregroundStyle(.red)
                }
            }

            participantSection(presentation)

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
        .environment(\.editMode, $listEditMode)
        .scrollDismissesKeyboard(.interactively)
        .confirmationDialog(
            pendingMacDisconnect.flatMap(presentation.disconnectConfirmation(for:))
                .map(TerminalSizingText.disconnectMacTitle) ?? "",
            isPresented: Binding(
                get: { pendingMacDisconnect != nil },
                set: { if !$0 { pendingMacDisconnect = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingMacDisconnect
        ) { row in
            Button(TerminalSizingText.disconnect(), role: .destructive) {
                run { await store.disconnectTerminalParticipant(row.id, surfaceID: surfaceID) }
            }
            .accessibilityIdentifier("MobileTerminalSizingDisconnectMacConfirm")
        } message: { _ in
            Text(TerminalSizingText.disconnectMacMessage())
        }
        .onAppear {
            let fixed = presentation.policy.fixed ?? presentation.grid
            fixedColumns = fixed.cols
            fixedRows = fixed.rows
            listEditMode = presentation.policy.mode == .priority ? .active : .inactive
        }
        .onChange(of: presentation.policy.mode) { _, mode in
            listEditMode = mode == .priority ? .active : .inactive
        }
        .onChange(of: fixedFieldFocused) { _, focused in
            if !focused { applyFixed(presentation) }
        }
    }

    @ViewBuilder
    private func participantSection(_ presentation: MobileTerminalSizingPresentation) -> some View {
        let rows = orderedRows(presentation)
        if presentation.policy.mode == .priority {
            Section {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    participantRow(row, priorityRank: index + 1, presentation: presentation)
                }
                .onMove { source, destination in
                    movePriority(presentation, from: source, to: destination)
                }
            } header: {
                Text(TerminalSizingText.priorityOrder())
            } footer: {
                Text(TerminalSizingText.modeDescription(.priority))
            }
        } else {
            Section {
                ForEach(Array(rows.enumerated()), id: \.element.id) { _, row in
                    participantRow(row, priorityRank: nil, presentation: presentation)
                }
            } header: {
                Text(TerminalSizingText.participants())
            }
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
        let priority = presentation.policy.migratingLegacyPriorityKeys(rows.map(\.participant)).priority
        let rank = Dictionary(
            priority.enumerated().map { ($1, $0) },
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
        priorityRank: Int?,
        presentation: MobileTerminalSizingPresentation
    ) -> some View {
        let isSelf = row.id == presentation.selfParticipant?.id
        let participant = row.participant
        let title = TerminalSizingText.participantTitle(participant, isSelf: isSelf)
        let status = TerminalSizingText.rowStatus(presentation.rowStatus(for: row))
        let rowView = HStack(spacing: 12) {
            if let priorityRank {
                Text(verbatim: "\(priorityRank)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .trailing)
            }
            // Full opacity when not counted, so the glyph keeps 4.5:1; the
            // secondary title and status say it.
            TerminalSizingAvatar(participant: participant, isOwner: presentation.ownerIDs == [row.id])
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
            if presentation.canDisconnect(row) {
                Button(TerminalSizingText.disconnect(), role: .destructive) {
                    requestDisconnect(row, presentation: presentation)
                }
            }
        }
        if presentation.canDisconnect(row) {
            return AnyView(rowView.contextMenu {
                Button(role: .destructive) {
                    requestDisconnect(row, presentation: presentation)
                } label: {
                    Label(TerminalSizingText.disconnect(), systemImage: "xmark.circle")
                }
            })
        }
        return AnyView(rowView)
    }

    /// Disconnects a phone at once; a Mac first confirms, naming that Mac,
    /// because its window loses the terminal (HIG: Alerts, destructive actions).
    private func requestDisconnect(
        _ row: TerminalSizingParticipantState,
        presentation: MobileTerminalSizingPresentation
    ) {
        if presentation.disconnectConfirmation(for: row) != nil {
            pendingMacDisconnect = row
        } else {
            run { await store.disconnectTerminalParticipant(row.id, surfaceID: surfaceID) }
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
                if mode == .priority {
                    let participants = presentation.participants.map(\.participant)
                    policy = policy.withCompletePriority(for: participants)
                }
                run { await store.setTerminalSizePolicy(policy, surfaceID: surfaceID) }
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
        let policy = presentation.policy
            .migratingLegacyPriorityKeys(presentation.participants.map(\.participant))
            .withReorderedPriority(visibleKeys: keys)
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
/// on a neutral fill. The sheet is standard UI, so its colors derive from the
/// inset-grouped row background and the label color through
/// ``TerminalSizingPalette`` (4.5:1 glyph, 3:1 owner ring), resolved per
/// trait environment.
private struct TerminalSizingAvatar: View {
    let participant: TerminalSizingParticipant
    let isOwner: Bool

    private static func color(_ role: TerminalSizingPalette.Role) -> Color {
        Color(uiColor: TerminalSizingPalette.dynamicColor(
            role,
            background: .secondarySystemGroupedBackground,
            foreground: .label
        ))
    }

    var body: some View {
        Circle()
            .fill(Self.color(.fill))
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
            .foregroundStyle(Self.color(.glyph))
            .overlay {
                if isOwner {
                    Circle()
                        .inset(by: -2)
                        .stroke(Self.color(.line), lineWidth: 1)
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
