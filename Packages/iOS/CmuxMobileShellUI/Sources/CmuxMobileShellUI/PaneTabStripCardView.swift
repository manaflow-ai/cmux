import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// One snapshot-isolated live card in the in-pane tab strip.
struct PaneTabStripCardView: View {
    let card: PaneTabStripCardSnapshot
    let isSelected: Bool
    let connectionStatus: MobileMacConnectionStatus
    let previewUpdates: (String) -> AsyncStream<PreviewGridSnapshot>
    let select: () -> Void
    @State private var isVisible = false
    @State private var snapshot: PreviewGridSnapshot

    init(
        card: PaneTabStripCardSnapshot,
        isSelected: Bool,
        connectionStatus: MobileMacConnectionStatus,
        previewUpdates: @escaping (String) -> AsyncStream<PreviewGridSnapshot>,
        select: @escaping () -> Void
    ) {
        self.card = card
        self.isSelected = isSelected
        self.connectionStatus = connectionStatus
        self.previewUpdates = previewUpdates
        self.select = select
        _snapshot = State(initialValue: .awaitingBaseline(surfaceID: card.id))
    }

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 5) {
                thumbnail
                HStack(spacing: 5) {
                    Text(resolvedTitle)
                        .font(.caption2.weight(isSelected ? .bold : .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if let statusSymbolName {
                        Image(systemName: statusSymbolName)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(statusTint)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(5)
            .frame(width: 128)
            .background(
                isSelected ? Color.accentColor.opacity(0.18) : Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .white.opacity(0.12), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(resolvedTitle)
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("MobilePaneTabCard-\(card.id)")
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            isVisible = visible
        }
        .task(id: previewTaskID) {
            await consumePreviewIfNeeded()
        }
    }

    private var thumbnail: some View {
        TerminalGridThumbnailView(snapshot: snapshot)
            .frame(height: 56)
            .background(TerminalPalette.background)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(connectionStatus == .connected ? 1 : 0.35)
    }

    private var resolvedTitle: String {
        card.title.isEmpty
            ? L10n.string("mobile.workspaceHub.untitled", defaultValue: "Untitled")
            : card.title
    }

    private var accessibilityValue: String {
        var values: [String] = []
        if isSelected {
            values.append(L10n.string("mobile.paneTabStrip.selected", defaultValue: "Selected"))
        }
        if card.agentStatus == .needsInput || card.hasUnread {
            values.append(L10n.string("mobile.workspaceHub.attention", defaultValue: "Needs attention"))
        }
        return values.joined(separator: ", ")
    }

    private var statusSymbolName: String? {
        if card.agentStatus == .needsInput { return "questionmark.bubble.fill" }
        if card.hasUnread { return "bell.badge.fill" }
        return switch card.agentStatus {
        case .running: "bolt.fill"
        case .idle: "pause.circle.fill"
        case .unknown: "circle.dashed"
        case .needsInput: "questionmark.bubble.fill"
        case nil: nil
        }
    }

    private var statusTint: Color {
        if card.agentStatus == .needsInput || card.hasUnread { return .orange }
        if card.agentStatus == .running { return .green }
        return .secondary
    }

    private var previewTaskID: String {
        "\(card.id)|\(isVisible)|\(connectionStatus == .connected)"
    }

    @MainActor
    private func consumePreviewIfNeeded() async {
        let visibleIDs = isVisible ? Set([card.id]) : []
        let demand = PaneTabStripPreviewDemand(cards: [card], visibleCardIDs: visibleIDs)
        guard connectionStatus == .connected, demand.surfaceIDs.contains(card.id) else { return }
        snapshot = .awaitingBaseline(surfaceID: card.id)
        for await update in previewUpdates(card.id) {
            guard !Task.isCancelled else { return }
            snapshot = update
        }
    }
}
