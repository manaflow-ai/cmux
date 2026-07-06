import CmuxAgentChat
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ChatBlockDetail: Identifiable, Equatable {
    struct Section: Identifiable, Equatable {
        enum Style: Equatable {
            case prose
            case monospaced
        }

        let id: String
        let title: String
        let text: String
        let style: Style
    }

    let id: String
    let title: String
    let subtitle: String?
    let sections: [Section]

    var copyText: String {
        sections
            .map(\.text)
            .joined(separator: "\n\n")
    }
}

extension ChatBlockDetail {
    static func make(message: ChatMessage) -> ChatBlockDetail? {
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

    static func make(block: TerminalCommandBlock) -> ChatBlockDetail {
        terminalDetail(id: "term-\(block.id)", command: block.command, output: block.output)
    }

    static func codeBlock(id: String, code: String, language: String?) -> ChatBlockDetail {
        let sectionTitle = language?.isEmpty == false
            ? language!.uppercased()
            : String(localized: "chat.detail.code.section", defaultValue: "Code", bundle: .module)
        return ChatBlockDetail(
            id: id,
            title: String(localized: "chat.detail.code.title", defaultValue: "Code Block", bundle: .module),
            subtitle: language?.isEmpty == false ? language : nil,
            sections: [
                Section(id: "code", title: sectionTitle, text: code, style: .monospaced),
            ]
        )
    }

    private static func thoughtDetail(id: String, thought: ChatThought) -> ChatBlockDetail {
        ChatBlockDetail(
            id: id,
            title: String(localized: "chat.thought.title", defaultValue: "Thought", bundle: .module),
            subtitle: nil,
            sections: [
                Section(
                    id: "reasoning",
                    title: String(localized: "chat.detail.thought.section", defaultValue: "Reasoning", bundle: .module),
                    text: thought.text,
                    style: .prose
                ),
            ]
        )
    }

    private static func toolDetail(id: String, toolUse: ChatToolUse) -> ChatBlockDetail {
        var sections: [Section] = []
        if let input = nonEmpty(toolUse.inputDetail) {
            sections.append(Section(
                id: "input",
                title: String(localized: "chat.detail.tool.input", defaultValue: "Input", bundle: .module),
                text: input,
                style: .monospaced
            ))
        }
        if let output = nonEmpty(toolUse.output) {
            sections.append(Section(
                id: "output",
                title: String(localized: "chat.detail.tool.output", defaultValue: "Output", bundle: .module),
                text: output,
                style: .monospaced
            ))
        }
        if sections.isEmpty {
            sections.append(Section(
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
            sections: sections
        )
    }

    private static func terminalDetail(id: String, command: String, output: String?) -> ChatBlockDetail {
        var sections = [
            Section(
                id: "command",
                title: String(localized: "chat.detail.command", defaultValue: "Command", bundle: .module),
                text: command,
                style: .monospaced
            ),
        ]
        if let output = nonEmpty(output) {
            sections.append(Section(
                id: "output",
                title: String(localized: "chat.detail.output", defaultValue: "Output", bundle: .module),
                text: ChatANSISanitizer().sanitized(output),
                style: .monospaced
            ))
        }
        return ChatBlockDetail(
            id: id,
            title: String(localized: "chat.detail.terminal.title", defaultValue: "Terminal Output", bundle: .module),
            subtitle: command.isEmpty ? nil : command,
            sections: sections
        )
    }

    private static func fileEditDetail(id: String, edit: ChatFileEdit) -> ChatBlockDetail {
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
            sections: [
                Section(
                    id: "diff",
                    title: String(localized: "chat.detail.diff", defaultValue: "Diff", bundle: .module),
                    text: text,
                    style: .monospaced
                ),
            ]
        )
    }

    private static func statusLabel(_ status: ChatToolUse.Status) -> String {
        switch status {
        case .running:
            return String(localized: "chat.detail.status.running", defaultValue: "Running", bundle: .module)
        case .succeeded:
            return String(localized: "chat.detail.status.succeeded", defaultValue: "Succeeded", bundle: .module)
        case .failed:
            return String(localized: "chat.detail.status.failed", defaultValue: "Failed", bundle: .module)
        }
    }

    private static func operationLabel(_ operation: ChatFileEdit.Operation) -> String {
        switch operation {
        case .edit:
            return String(localized: "chat.detail.operation.edit", defaultValue: "Edit", bundle: .module)
        case .write:
            return String(localized: "chat.detail.operation.write", defaultValue: "Write", bundle: .module)
        case .delete:
            return String(localized: "chat.detail.operation.delete", defaultValue: "Delete", bundle: .module)
        }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

struct ChatBlockDetailSheetView: View {
    let detail: ChatBlockDetail

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let subtitle = detail.subtitle, !subtitle.isEmpty {
                        Text(verbatim: subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    ForEach(detail.sections) { section in
                        ChatBlockDetailSectionView(section: section)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(detail.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "chat.detail.done", defaultValue: "Done", bundle: .module)) {
                        dismiss()
                    }
                    .accessibilityIdentifier("ChatBlockDetailDoneButton")
                }
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) { copyAllButton }
                #else
                ToolbarItem(placement: .confirmationAction) { copyAllButton }
                #endif
            }
        }
        .accessibilityIdentifier("ChatBlockDetailSheet")
    }

    private var copyAllButton: some View {
        Button(action: copyAll) {
            Text(String(localized: "chat.detail.copy_all", defaultValue: "Copy All", bundle: .module))
                .fontWeight(.regular)
        }
        .disabled(detail.copyText.isEmpty)
        .accessibilityIdentifier("ChatBlockDetailCopyAllButton")
    }

    private func copyAll() {
        guard !detail.copyText.isEmpty else { return }
        #if canImport(UIKit)
        UIPasteboard.general.string = detail.copyText
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(detail.copyText, forType: .string)
        #endif
    }
}

private struct ChatBlockDetailSectionView: View {
    let section: ChatBlockDetail.Section

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: section.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch section.style {
        case .prose:
            Text(verbatim: section.text.isEmpty ? " " : section.text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .monospaced:
            ScrollView(.horizontal, showsIndicators: true) {
                Text(verbatim: section.text.isEmpty ? " " : section.text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(10)
            }
            .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 8))
        }
    }
}
