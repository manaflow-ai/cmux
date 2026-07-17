internal import Foundation
internal import SwiftUI

/// Quick note editor for sending selected diff context to the workspace agent.
struct DiffQuickNoteSheet: View {
    let context: DiffNoteContext
    let sendToAgent: (@MainActor (String) async throws -> Void)?
    let editInComposer: (@MainActor (String) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var isSending = false
    @State private var sendFailed = false
    private let formatter = DiffPromptFormatter()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: context.path)
                            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                            .textSelection(.enabled)
                        Text(lineLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(verbatim: context.hunkReference)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.blue)
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(verbatim: context.excerpt)
                                .font(.system(size: 11, design: .monospaced))
                                .fixedSize(horizontal: true, vertical: false)
                                .textSelection(.enabled)
                        }
                        .padding(8)
                        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                } header: {
                    Text(String(localized: "diff.note.context", defaultValue: "Selected context", bundle: .module))
                }

                Section {
                    TextField(
                        String(localized: "diff.note.placeholder", defaultValue: "What should the agent know?", bundle: .module),
                        text: $note,
                        axis: .vertical
                    )
                    .lineLimit(3...8)
                } header: {
                    Text(String(localized: "diff.note.note", defaultValue: "Note", bundle: .module))
                }

                if sendFailed {
                    Text(String(
                        localized: "diff.note.sendError",
                        defaultValue: "Couldn’t send the note. Check the connection and try again.",
                        bundle: .module
                    ))
                    .font(.footnote)
                    .foregroundStyle(.red)
                }

                Section {
                    Button {
                        send()
                    } label: {
                        if isSending {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text(String(localized: "diff.note.send", defaultValue: "Send", bundle: .module))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(sendToAgent == nil || trimmedNote.isEmpty || isSending)

                    Button(String(
                        localized: "diff.note.editComposer",
                        defaultValue: "Edit in composer",
                        bundle: .module
                    )) {
                        editInComposer?(formattedPrompt)
                        dismiss()
                    }
                    .disabled(editInComposer == nil || isSending)
                }
            }
            .navigationTitle(String(localized: "diff.note.title", defaultValue: "Send to agent", bundle: .module))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "diff.note.cancel", defaultValue: "Cancel", bundle: .module)) {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var lineLabel: String {
        let format = if context.lineReference.isOld {
            String(localized: "diff.note.oldLine", defaultValue: "Old line %lld", bundle: .module)
        } else {
            String(localized: "diff.note.line", defaultValue: "Line %lld", bundle: .module)
        }
        return String(format: format, locale: .current, context.lineReference.number)
    }

    private var trimmedNote: String {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var formattedPrompt: String {
        formatter.prompt(context: context, note: note)
    }

    private func send() {
        guard let sendToAgent, !trimmedNote.isEmpty else { return }
        isSending = true
        sendFailed = false
        Task {
            do {
                try await sendToAgent(formattedPrompt)
                dismiss()
            } catch {
                isSending = false
                sendFailed = true
            }
        }
    }
}
