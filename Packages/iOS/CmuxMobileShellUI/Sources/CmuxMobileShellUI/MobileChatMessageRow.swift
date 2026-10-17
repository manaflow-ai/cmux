import CmuxAgentChat
import SwiftUI

/// Renders one typed transcript item as a native message, tool, or action card.
struct MobileChatMessageRow: View {
    let message: ChatMessage
    let onAnswer: (Int) -> Void

    var body: some View {
        switch message.kind {
        case .prose(let prose):
            MobileChatProseRow(role: message.role, text: prose.text)
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

    var body: some View {
        HStack {
            if role == .user { Spacer(minLength: 38) }
            Text(text)
                .font(.body)
                .foregroundStyle(role == .user ? .white : .primary)
                .textSelection(.enabled)
                .padding(.horizontal, role == .user ? 14 : 0)
                .padding(.vertical, role == .user ? 11 : 2)
                .background {
                    if role == .user {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.accentColor)
                    }
                }
            if role != .user { Spacer(minLength: 38) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(role == .user ? "MobileChatUserMessage" : "MobileChatAgentMessage")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                Text(tool.summary)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Spacer()
                Text(statusTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
            }
            if let output = tool.output, !output.isEmpty {
                Text(output)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(terminal.command, systemImage: terminal.isRunning ? "play.fill" : "terminal")
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            if let output = terminal.output, !output.isEmpty {
                Text(output)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
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
