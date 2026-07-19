import CmuxAgentChat
import Foundation

struct ChatBlockDetailBuilder {
    private let sanitizer: ChatANSISanitizer

    init(sanitizer: ChatANSISanitizer = ChatANSISanitizer()) {
        self.sanitizer = sanitizer
    }

    func detail(message: ChatMessage) -> ChatBlockDetail? {
        switch message.kind {
        case .prose, .permissionRequest, .question, .status, .attachment, .unsupported:
            return nil
        case .thought(let thought):
            return thoughtDetail(id: "msg-\(message.id)", thought: thought)
        case .toolUse(let toolUse):
            return toolDetail(id: "msg-\(message.id)", toolUse: toolUse)
        case .terminal(let capture):
            return terminalDetail(id: "msg-\(message.id)", command: capture.command, output: capture.output)
        case .fileEdit(let edit):
            return fileEditDetail(id: "msg-\(message.id)", edit: edit)
        }
    }

    func detail(block: TerminalCommandBlock) -> ChatBlockDetail {
        terminalDetail(id: "term-\(block.id)", command: block.command, output: block.output)
    }

    func codeBlock(id: String, code: String, language: String?) -> ChatBlockDetail {
        let sectionTitle = language?.isEmpty == false
            ? language!.uppercased()
            : String(localized: "chat.detail.code.section", defaultValue: "Code", bundle: .module)
        return ChatBlockDetail(
            id: id,
            title: String(localized: "chat.detail.code.title", defaultValue: "Code Block", bundle: .module),
            subtitle: language?.isEmpty == false ? language : nil,
            artifactPaths: [],
            sections: [
                ChatBlockDetailSection(id: "code", title: sectionTitle, text: code, style: .monospaced),
            ]
        )
    }

    private func thoughtDetail(id: String, thought: ChatThought) -> ChatBlockDetail {
        ChatBlockDetail(
            id: id,
            title: String(localized: "chat.thought.title", defaultValue: "Thought", bundle: .module),
            subtitle: nil,
            artifactPaths: [],
            sections: [
                ChatBlockDetailSection(
                    id: "reasoning",
                    title: String(localized: "chat.detail.thought.section", defaultValue: "Reasoning", bundle: .module),
                    text: thought.text,
                    style: .prose
                ),
            ]
        )
    }

    private func toolDetail(id: String, toolUse: ChatToolUse) -> ChatBlockDetail {
        var sections: [ChatBlockDetailSection] = []
        if let input = nonEmpty(toolUse.inputDetail) {
            sections.append(ChatBlockDetailSection(
                id: "input",
                title: String(localized: "chat.detail.tool.input", defaultValue: "Input", bundle: .module),
                text: input,
                style: .monospaced
            ))
        }
        if let output = nonEmpty(toolUse.output) {
            sections.append(ChatBlockDetailSection(
                id: "output",
                title: String(localized: "chat.detail.tool.output", defaultValue: "Output", bundle: .module),
                text: output,
                style: .monospaced
            ))
        }
        if sections.isEmpty {
            sections.append(ChatBlockDetailSection(
                id: "summary",
                title: String(localized: "chat.detail.tool.summary", defaultValue: "Summary", bundle: .module),
                text: toolUse.summary,
                style: .prose
            ))
        }
        let status = statusLabel(toolUse.status)
        return ChatBlockDetail(
            id: id,
            title: String(localized: "chat.detail.tool.title", defaultValue: "Tool Details", bundle: .module),
            subtitle: String(
                localized: "chat.detail.tool.subtitle",
                defaultValue: "\(toolUse.toolName) - \(status)",
                bundle: .module
            ),
            artifactPaths: toolUse.referencedPaths ?? [],
            sections: sections
        )
    }

    private func terminalDetail(id: String, command: String, output: String?) -> ChatBlockDetail {
        var sections = [
            ChatBlockDetailSection(
                id: "command",
                title: String(localized: "chat.detail.command", defaultValue: "Command", bundle: .module),
                text: command,
                style: .monospaced
            ),
        ]
        if let output = nonEmpty(output) {
            sections.append(ChatBlockDetailSection(
                id: "output",
                title: String(localized: "chat.detail.output", defaultValue: "Output", bundle: .module),
                text: sanitizer.sanitized(output),
                style: .monospaced
            ))
        }
        return ChatBlockDetail(
            id: id,
            title: String(localized: "chat.detail.terminal.title", defaultValue: "Terminal Output", bundle: .module),
            subtitle: command.isEmpty ? nil : command,
            artifactPaths: [],
            sections: sections
        )
    }

    private func fileEditDetail(id: String, edit: ChatFileEdit) -> ChatBlockDetail {
        let details = [
            operationLabel(edit.operation),
            edit.additions.map { "+\($0)" },
            edit.deletions.map { "-\($0)" },
        ]
        .compactMap(\.self)
        .joined(separator: " ")
        let subtitle = details.isEmpty
            ? edit.filePath
            : String(
                localized: "chat.detail.file.subtitle",
                defaultValue: "\(edit.filePath) - \(details)",
                bundle: .module
            )
        let text = nonEmpty(edit.unifiedDiff)
            ?? String(localized: "chat.detail.empty", defaultValue: "No details available", bundle: .module)
        return ChatBlockDetail(
            id: id,
            title: String(localized: "chat.detail.file.title", defaultValue: "File Change", bundle: .module),
            subtitle: subtitle,
            artifactPaths: [edit.filePath],
            sections: [
                ChatBlockDetailSection(
                    id: "diff",
                    title: String(localized: "chat.detail.diff", defaultValue: "Diff", bundle: .module),
                    text: text,
                    style: .monospaced
                ),
            ]
        )
    }

    private func statusLabel(_ status: ChatToolUse.Status) -> String {
        switch status {
        case .running:
            return String(localized: "chat.detail.status.running", defaultValue: "Running", bundle: .module)
        case .succeeded:
            return String(localized: "chat.detail.status.succeeded", defaultValue: "Succeeded", bundle: .module)
        case .failed:
            return String(localized: "chat.detail.status.failed", defaultValue: "Failed", bundle: .module)
        }
    }

    private func operationLabel(_ operation: ChatFileEdit.Operation) -> String {
        switch operation {
        case .edit:
            return String(localized: "chat.detail.operation.edit", defaultValue: "Edit", bundle: .module)
        case .write:
            return String(localized: "chat.detail.operation.write", defaultValue: "Write", bundle: .module)
        case .delete:
            return String(localized: "chat.detail.operation.delete", defaultValue: "Delete", bundle: .module)
        }
    }

    private func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
