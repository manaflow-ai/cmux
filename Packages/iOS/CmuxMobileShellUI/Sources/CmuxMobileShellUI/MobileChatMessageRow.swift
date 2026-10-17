import CmuxAgentChat
import SwiftUI
import UIKit

/// Renders one typed transcript item as a native message, tool, or action card.
struct MobileChatMessageRow: View {
    let message: ChatMessage
    let feedback: MobileChatFeedback?
    let onFeedback: (MobileChatFeedback) -> Void
    let onAnswer: (Int) -> Void

    var body: some View {
        switch message.kind {
        case .prose(let prose):
            MobileChatProseRow(
                role: message.role,
                text: prose.text,
                feedback: feedback,
                onFeedback: onFeedback
            )
        case .thought(let thought):
            MobileChatThoughtRow(text: thought.text)
        case .toolUse(let tool):
            MobileChatToolRow(tool: tool)
        case .terminal(let terminal):
            MobileChatTerminalRow(terminal: terminal)
        case .fileEdit(let edit):
            MobileChatFileEditRow(edit: edit)
        case .permissionRequest(let request):
            MobileChatPermissionRow(request: request, onAnswer: onAnswer)
        case .question(let question):
            MobileChatQuestionRow(question: question, onAnswer: onAnswer)
        case .status(let status):
            MobileChatStatusRow(status: status)
        case .attachment(let attachment):
            MobileChatAttachmentRow(attachment: attachment)
        case .unsupported(let payload):
            MobileChatUnsupportedRow(typeName: payload.rawType)
        }
    }
}

private struct MobileChatProseRow: View {
    let role: ChatRole
    let text: String
    let feedback: MobileChatFeedback?
    let onFeedback: (MobileChatFeedback) -> Void

    var body: some View {
        VStack(alignment: role == .user ? .trailing : .leading, spacing: 7) {
            HStack(alignment: .top, spacing: role == .user ? 0 : 10) {
                if role == .user {
                    Spacer(minLength: 38)
                } else {
                    Image(systemName: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 24, height: 24)
                        .background(Color.accentColor.opacity(0.12), in: Circle())
                        .accessibilityHidden(true)
                }
                MobileChatMarkdownText(text: text)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, role == .user ? 14 : 0)
                    .padding(.vertical, role == .user ? 11 : 2)
                    .background {
                        if role == .user {
                            RoundedRectangle(cornerRadius: 19, style: .continuous)
                                .fill(Color.accentColor.opacity(0.14))
                        }
                    }
                if role != .user { Spacer(minLength: 26) }
            }
            if role != .user {
                HStack(spacing: 14) {
                    MobileChatCopyButton(text: text)
                    Button {
                        onFeedback(.positive)
                    } label: {
                        Image(systemName: feedback == .positive ? "hand.thumbsup.fill" : "hand.thumbsup")
                    }
                    .foregroundStyle(feedback == .positive ? Color.accentColor : .secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Good response")
                    .accessibilityValue(feedback == .positive ? "Selected" : "")
                    .accessibilityIdentifier("MobileChatThumbsUp")
                    Button {
                        onFeedback(.negative)
                    } label: {
                        Image(systemName: feedback == .negative ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    }
                    .foregroundStyle(feedback == .negative ? Color.accentColor : .secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Needs improvement")
                    .accessibilityValue(feedback == .negative ? "Selected" : "")
                    .accessibilityIdentifier("MobileChatThumbsDown")
                }
                .font(.caption)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(role == .user ? "MobileChatUserMessage" : "MobileChatAgentMessage")
    }
}

private struct MobileChatMarkdownText: View {
    let text: String

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .full)
        ) {
            Text(attributed)
                .font(.body)
                .textSelection(.enabled)
        } else {
            Text(text)
                .font(.body)
                .textSelection(.enabled)
        }
    }
}

private struct MobileChatCopyButton: View {
    let text: String

    var body: some View {
        Button {
            UIPasteboard.general.string = text
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel("Copy response")
    }
}

private struct MobileChatThoughtRow: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 6)
        } label: {
            Label("Thought", systemImage: "lightbulb")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("MobileChatThought")
    }
}

private struct MobileChatToolRow: View {
    let tool: ChatToolUse
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if let output = tool.output, !output.isEmpty {
                Text(output)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            } else {
                Text(tool.toolName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.summary)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    Text(tool.toolName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(statusTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("MobileChatToolCard")
    }

    private var icon: String {
        switch tool.status {
        case .running: "arrow.triangle.2.circlepath"
        case .succeeded: "checkmark.circle"
        case .failed: "xmark.circle"
        }
    }

    private var statusTitle: String {
        switch tool.status {
        case .running: "Running"
        case .succeeded: "Done"
        case .failed: "Failed"
        }
    }

    private var statusColor: Color {
        switch tool.status {
        case .running: .blue
        case .succeeded: .green
        case .failed: .red
        }
    }
}

private struct MobileChatTerminalRow: View {
    let terminal: ChatTerminalCapture
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if let output = terminal.output, !output.isEmpty {
                Text(output)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
        } label: {
            Label(terminal.command, systemImage: terminal.isRunning ? "play.fill" : "terminal")
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
        }
        .padding(12)
        .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("MobileChatTerminalCard")
    }
}

private struct MobileChatFileEditRow: View {
    let edit: ChatFileEdit

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 3) {
                Text(edit.filePath)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(edit.operation.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let additions = edit.additions {
                Text("+\(additions)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
            if let deletions = edit.deletions {
                Text("−\(deletions)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("MobileChatFileEditCard")
    }
}

private struct MobileChatPermissionRow: View {
    let request: ChatPermissionRequest
    let onAnswer: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(request.title, systemImage: "hand.raised.fill")
                .font(.subheadline.weight(.semibold))
            Text(request.subject)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            if let resolution = request.resolution {
                Text(resolution.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("Allow") { onAnswer(0) }
                        .buttonStyle(.borderedProminent)
                    Button("Deny") { onAnswer(1) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(13)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier("MobileChatPermissionCard")
    }
}

private struct MobileChatQuestionRow: View {
    let question: ChatQuestion
    let onAnswer: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.prompt)
                .font(.body.weight(.medium))
            if let selected = question.selectedOptionLabel {
                Label(selected, systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            } else {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    Button {
                        onAnswer(index)
                    } label: {
                        HStack {
                            Text(option.label)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(13)
        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier("MobileChatQuestionCard")
    }
}

private struct MobileChatStatusRow: View {
    let status: ChatStatusTransition

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.separator).frame(height: 1)
            Text(status.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Rectangle().fill(.separator).frame(height: 1)
        }
        .accessibilityIdentifier("MobileChatStatusRow")
    }
}

private struct MobileChatAttachmentRow: View {
    let attachment: ChatAttachment

    var body: some View {
        Label(
            attachment.displayName ?? "Attachment",
            systemImage: attachment.media == .image ? "photo" : "paperclip"
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.quaternary, in: Capsule())
        .accessibilityIdentifier("MobileChatAttachment")
    }
}

private struct MobileChatUnsupportedRow: View {
    let typeName: String

    var body: some View {
        Label("Unsupported message: \(typeName)", systemImage: "questionmark.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private extension ChatFileEdit.Operation {
    var displayName: String {
        switch self {
        case .edit: "Edited"
        case .write: "Created"
        case .delete: "Deleted"
        }
    }
}

private extension ChatPermissionRequest.Resolution {
    var displayName: String {
        switch self {
        case .approved: "Allowed"
        case .denied: "Denied"
        case .expired: "Expired"
        }
    }
}

private extension ChatStatusTransition {
    var title: String {
        switch event {
        case .sessionStarted: "Session started"
        case .sessionEnded: detail ?? "Session ended"
        case .interrupted: "Interrupted"
        case .contextCompacted: "Context compacted"
        }
    }
}
