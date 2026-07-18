import CmuxAgentChat
import SwiftUI

/// Renders one transcript message by switching over its kind: bubbles for
/// prose, near-full-width cards for terminal/diff content, actionable cards
/// for permissions and questions, captions for status rows.
public struct ChatMessageRowView: View {
    private let snapshot: ChatMessageRowSnapshot
    private let actions: ChatRowActions

    @Environment(\.chatTheme) private var theme

    /// Creates the renderer.
    ///
    /// - Parameters:
    ///   - snapshot: The message plus its computed group rendering info.
    ///   - actions: Row action bundle.
    public init(snapshot: ChatMessageRowSnapshot, actions: ChatRowActions) {
        self.snapshot = snapshot
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
                    showsTimestamp: snapshot.showsTimestamp,
                    onShowCodeDetail: actions.showCodeBlockDetail
                )
            case .thought:
                ChatThoughtRowView(
                    rowID: rowID,
                    onShowDetail: { actions.showMessageDetail(snapshot.message) }
                )
            case .toolUse(let toolUse):
                ChatToolUseRowView(
                    toolUse: toolUse,
                    rowID: rowID,
                    onShowDetail: { actions.showMessageDetail(snapshot.message) }
                )
            case .terminal(let capture):
                ChatTerminalCardView(
                    capture: capture,
                    rowID: rowID,
                    onShowDetail: { actions.showMessageDetail(snapshot.message) }
                )
            case .fileEdit(let edit):
                ChatFileEditCardView(
                    edit: edit,
                    rowID: rowID,
                    onShowDetail: { actions.showMessageDetail(snapshot.message) }
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
                    timestamp: snapshot.message.timestamp,
                    onOpenArtifact: actions.openArtifact
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
