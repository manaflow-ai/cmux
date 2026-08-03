import CmuxAgentChat
import SwiftUI

/// Dispatches one ``ChatTranscriptRow`` to its renderer.
///
/// Equatable so SwiftUI skips body re-evaluation for rows whose snapshot
/// did not change while the transcript updates around them.
public struct ChatTranscriptRowView: View, Equatable {
    private let row: ChatTranscriptRow
    private let actions: ChatRowActions

    /// Creates the dispatcher.
    ///
    /// - Parameters:
    ///   - row: The row snapshot to render.
    ///   - actions: Row action bundle.
    public init(row: ChatTranscriptRow, actions: ChatRowActions) {
        self.row = row
        self.actions = actions
    }

    /// Compares only render-relevant value state; the action closures are
    /// intentionally excluded.
    nonisolated public static func == (lhs: ChatTranscriptRowView, rhs: ChatTranscriptRowView) -> Bool {
        lhs.row == rhs.row
    }

    public var body: some View {
        switch row {
        case .dateHeader(let day):
            ChatDateHeaderBridge(day: day)
        case .unreadSeparator:
            ChatUnreadSeparatorBridge()
        case .message(let snapshot):
            ChatMessageRowView(snapshot: snapshot, actions: actions)
        case .pendingOutbound(let pending):
            ChatPendingBubbleView(pending: pending, actions: actions)
        case .terminalCommand(let block):
            TerminalCommandBlockView(
                block: block,
                onOpenTerminal: actions.openTerminal,
                onShowDetail: { actions.showTerminalCommandDetail(block) }
            )
        }
    }
}

#if os(iOS)
private struct ChatDateHeaderBridge: UIViewRepresentable {
    let day: Date

    func makeUIView(context: Context) -> ChatDateHeaderView {
        ChatDateHeaderView(day: day)
    }

    func updateUIView(_ view: ChatDateHeaderView, context: Context) {}
}

private struct ChatUnreadSeparatorBridge: UIViewRepresentable {
    func makeUIView(context: Context) -> ChatUnreadSeparatorView {
        ChatUnreadSeparatorView()
    }

    func updateUIView(_ view: ChatUnreadSeparatorView, context: Context) {}
}
#endif
