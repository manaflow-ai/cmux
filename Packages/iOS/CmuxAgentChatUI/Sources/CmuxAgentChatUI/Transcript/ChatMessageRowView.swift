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
                    onShowCodeDetail: actions.showCodeBlockDetail,
                    onCopied: actions.notifyCopied
                )
                .equatable()
            case .thought:
                ChatThoughtRowBridge(
                    rowID: rowID,
                    onShowDetail: { actions.showMessageDetail(snapshot.message) }
                )
            case .toolUse(let toolUse):
                ChatToolUseRowBridge(
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
                ChatStatusRowBridge(transition: transition, timestamp: snapshot.message.timestamp)
            case .attachment(let attachment):
                ChatAttachmentBubbleView(
                    attachment: attachment,
                    groupPosition: snapshot.groupPosition,
                    showsTimestamp: snapshot.showsTimestamp,
                    timestamp: snapshot.message.timestamp,
                    onOpenArtifact: actions.openArtifact
                )
            case .unsupported(let payload):
                ChatUnsupportedRowBridge(payload: payload)
            }
        }
        .padding(.top, snapshot.groupPosition.topSpacing(theme: theme))
    }

    private var rowID: String {
        ChatTranscriptRow.message(snapshot).id
    }
}

#if os(iOS)
private struct ChatThoughtRowBridge: UIViewRepresentable {
    let rowID: String
    let onShowDetail: @MainActor () -> Void

    func makeUIView(context: Context) -> ChatThoughtRowView {
        ChatThoughtRowView(rowID: rowID, onShowDetail: onShowDetail)
    }

    func updateUIView(_ view: ChatThoughtRowView, context: Context) {}
}

private struct ChatToolUseRowBridge: UIViewRepresentable {
    let toolUse: ChatToolUse
    let rowID: String
    let onShowDetail: @MainActor () -> Void

    func makeUIView(context: Context) -> ChatToolUseRowView {
        ChatToolUseRowView(toolUse: toolUse, rowID: rowID, onShowDetail: onShowDetail)
    }

    func updateUIView(_ view: ChatToolUseRowView, context: Context) {}
}

private struct ChatStatusRowBridge: UIViewRepresentable {
    let transition: ChatStatusTransition
    let timestamp: Date

    func makeUIView(context: Context) -> ChatStatusRowView {
        ChatStatusRowView(transition: transition, timestamp: timestamp)
    }

    func updateUIView(_ view: ChatStatusRowView, context: Context) {}
}

private struct ChatUnsupportedRowBridge: UIViewRepresentable {
    let payload: ChatUnsupportedPayload

    func makeUIView(context: Context) -> ChatUnsupportedRowView {
        ChatUnsupportedRowView(payload: payload)
    }

    func updateUIView(_ view: ChatUnsupportedRowView, context: Context) {}
}
#endif

extension ChatGroupPosition {
    /// Vertical spacing above a row given its position in a bubble group.
    func topSpacing(theme: ChatTheme) -> CGFloat {
        switch self {
        case .solo, .first: return theme.groupSpacing
        case .middle, .last: return theme.intraGroupSpacing
        }
    }
}
