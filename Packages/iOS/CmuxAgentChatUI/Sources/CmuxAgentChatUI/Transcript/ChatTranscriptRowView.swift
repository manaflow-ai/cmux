import CmuxAgentChat
import SwiftUI

/// Dispatches one ``ChatTranscriptRow`` to its renderer.
///
/// Equatable so SwiftUI skips body re-evaluation for rows whose snapshot
/// and expansion state did not change while the transcript updates around
/// them.
public struct ChatTranscriptRowView: View, Equatable {
    private let row: ChatTranscriptRow
    private let isExpanded: Bool
    private let actions: ChatRowActions

    /// Creates the dispatcher.
    ///
    /// - Parameters:
    ///   - row: The row snapshot to render.
    ///   - isExpanded: Whether this row's card is expanded.
    ///   - actions: Row action bundle.
    public init(row: ChatTranscriptRow, isExpanded: Bool, actions: ChatRowActions) {
        self.row = row
        self.isExpanded = isExpanded
        self.actions = actions
    }

    /// Compares only render-relevant value state; the action closures are
    /// intentionally excluded.
    nonisolated public static func == (lhs: ChatTranscriptRowView, rhs: ChatTranscriptRowView) -> Bool {
        lhs.row == rhs.row && lhs.isExpanded == rhs.isExpanded
    }

    public var body: some View {
        switch row {
        case .dateHeader(let day):
            ChatDateHeaderView(day: day)
        case .unreadSeparator:
            ChatUnreadSeparatorView()
        case .message(let snapshot):
            ChatMessageRowView(snapshot: snapshot, isExpanded: isExpanded, actions: actions)
        case .pendingOutbound(let pending):
            ChatPendingBubbleView(pending: pending, actions: actions)
        case .terminalCommand(let block):
            TerminalCommandBlockView(
                block: block,
                isExpanded: isExpanded,
                onToggleExpanded: { actions.toggleExpanded(row.id) },
                onOpenTerminal: actions.openTerminal
            )
        }
    }
}
