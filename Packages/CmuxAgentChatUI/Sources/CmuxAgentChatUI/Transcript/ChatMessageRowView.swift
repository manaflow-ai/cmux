import CmuxAgentChat
import SwiftUI

/// Renders one transcript message by switching over its kind: bubbles for
/// prose, near-full-width cards for terminal/diff content, actionable cards
/// for permissions and questions, captions for status rows.
public struct ChatMessageRowView: View {
    private let snapshot: ChatMessageRowSnapshot
    private let isExpanded: Bool
    private let actions: ChatRowActions

    @Environment(\.chatTheme) private var theme

    /// Creates the renderer.
    ///
    /// - Parameters:
    ///   - snapshot: The message plus its computed group rendering info.
    ///   - isExpanded: Whether this row's card is expanded.
    ///   - actions: Row action bundle.
    public init(snapshot: ChatMessageRowSnapshot, isExpanded: Bool, actions: ChatRowActions) {
        self.snapshot = snapshot
        self.isExpanded = isExpanded
        self.actions = actions
    }

    public var body: some View {
        Group {
            switch snapshot.message.kind {
            case .prose(let prose):
                ChatProseBubbleView(
                    prose: prose,
                    message: snapshot.message,
                    groupPosition: snapshot.groupPosition,
                    showsTimestamp: snapshot.showsTimestamp
                )
            case .thought(let thought):
                ChatThoughtRowView(
                    thought: thought,
                    rowID: rowID,
                    isExpanded: isExpanded,
                    actions: actions
                )
            case .toolUse(let toolUse):
                ChatToolUseRowView(
                    toolUse: toolUse,
                    rowID: rowID,
                    isExpanded: isExpanded,
                    actions: actions
                )
            case .terminal(let capture):
                ChatTerminalCardView(
                    capture: capture,
                    rowID: rowID,
                    isExpanded: isExpanded,
                    actions: actions
                )
            case .fileEdit(let edit):
                ChatFileEditCardView(
                    edit: edit,
                    rowID: rowID,
                    isExpanded: isExpanded,
                    actions: actions
                )
            case .permissionRequest(let request):
                ChatPermissionCardView(
                    request: request,
                    timestamp: snapshot.message.timestamp,
                    actions: actions
                )
            case .question(let question):
                ChatQuestionCardView(question: question, actions: actions)
            case .status(let transition):
                ChatStatusRowView(transition: transition, timestamp: snapshot.message.timestamp)
            case .attachment(let attachment):
                ChatAttachmentBubbleView(
                    attachment: attachment,
                    groupPosition: snapshot.groupPosition,
                    showsTimestamp: snapshot.showsTimestamp,
                    timestamp: snapshot.message.timestamp
                )
            case .unsupported(let payload):
                ChatUnsupportedRowView(payload: payload)
            }
        }
        .padding(.top, snapshot.groupPosition.topSpacing(theme: theme))
    }

    private var rowID: String {
        ChatTranscriptRow.message(snapshot).id
    }
}

extension ChatGroupPosition {
    /// Vertical spacing above a row given its position in a bubble group.
    func topSpacing(theme: ChatTheme) -> CGFloat {
        switch self {
        case .solo, .first: return theme.groupSpacing
        case .middle, .last: return theme.intraGroupSpacing
        }
    }
}
