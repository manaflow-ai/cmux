import CmuxAgentBrands
import CmuxNextDesign
import SwiftUI

/// One entry of the history page.
struct HistoryPageRow: View {
    let entry: HistoryEntry
    let colors: HistoryPageColors

    var body: some View {
        HStack(spacing: Metrics.panelInset * 1.5) {
            icon
                .frame(width: Metrics.iconSize, height: Metrics.iconSize)
                .foregroundStyle(colors.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(Font(Typography.body)).foregroundStyle(entry.isAvailable ? colors.primary : colors.tertiary)
                    .lineLimit(1).truncationMode(.tail)
                if let detail = detailText {
                    Text(detail).font(Font(Typography.caption)).foregroundStyle(colors.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: Metrics.panelInset)
            if let badge {
                Text(badge).font(Font(Typography.caption)).foregroundStyle(colors.secondary)
            }
            Text(entry.time.formatted(date: .omitted, time: .shortened))
                .font(Font(Typography.caption)).foregroundStyle(colors.tertiary).monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    private var detailText: String? {
        let parts = [entry.detail, entry.machineName].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var badge: String? {
        if !entry.isAvailable { return HistoryStrings.offline }
        switch entry.payload {
        case .location(_, let isCurrent) where isCurrent: return HistoryStrings.current
        case .agent(let session) where session.endedAt == nil: return HistoryStrings.running
        default: return nil
        }
    }

    /// An agent session wears its agent's brand mark (design/agent-icons); other kinds a symbol.
    @ViewBuilder private var icon: some View {
        if case .agent(let session) = entry.payload {
            AgentBrandMark(agent: session.provider, size: Metrics.iconSize)
        } else {
            Image(systemName: Self.symbol(entry.kind))
        }
    }

    static func symbol(_ kind: HistoryEntry.Kind) -> String {
        switch kind {
        case .page: "globe"
        case .location: "location"
        case .closed: "arrow.uturn.backward"
        case .command: "terminal"
        case .agent: "sparkles"
        }
    }
}

/// The row's context menu.
struct HistoryPageMenu: View {
    let entry: HistoryEntry
    let model: HistoryPageModel

    var body: some View {
        switch entry.payload {
        case .page(let url, _):
            Button(HistoryStrings.open) { model.open(entry) }
            Button(HistoryStrings.openInNewTab) { model.open(entry, newTab: true) }
            Button(HistoryStrings.copyURL) { model.copy(url) }
            Divider()
            Button(HistoryStrings.removeSite, role: .destructive) { model.removeSite(of: entry) }
        case .location:
            Button(HistoryStrings.goTo) { model.open(entry) }
        case .closed(let item):
            Button(HistoryStrings.reopen) { model.open(entry) }
            if let url = item.url { Button(HistoryStrings.copyURL) { model.copy(url) } }
        case .agent(let session):
            Button(HistoryStrings.resume) { model.open(entry) }
            Button(HistoryStrings.copySessionID) { model.copy(session.sessionID) }
        case .command(let command):
            if let text = command.command {
                Button(HistoryStrings.runAgain) { model.open(entry) }
                Button(HistoryStrings.copyCommand) { model.copy(text) }
            }
        }
        Button(HistoryStrings.remove, role: .destructive) { model.remove(entry) }
    }
}
