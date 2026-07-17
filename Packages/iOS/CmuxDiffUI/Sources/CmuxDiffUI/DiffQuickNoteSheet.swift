import SwiftUI

struct DiffQuickNoteSheet: View {
    let target: DiffQuickNoteTarget
    let actions: DiffQuickNoteActions
    let dismissViewer: @MainActor () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var isSending = false

    var body: some View {
        NavigationStack {
            Form {
                Section(previewLabel) {
                    ScrollView(.horizontal) {
                        Text(DiffPromptFormatter().preview(target: target))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                Section(noteLabel) {
                    TextField(notePlaceholder, text: $note, axis: .vertical)
                        .lineLimit(3...8)
                }
                if !actions.isAvailable {
                    Section {
                        Label(unavailableHint, systemImage: "bubble.left")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(cancelLabel) { dismiss() }
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button(editLabel) { editInComposer() }
                        .disabled(!actions.isAvailable || isSending)
                    Button(sendLabel) { send() }
                        .disabled(!actions.isAvailable || isSending)
                }
            }
        }
    }

    @MainActor private func send() {
        let prompt = DiffPromptFormatter().format(target: target, note: note)
        isSending = true
        Task {
            await actions.send(prompt)
            dismiss()
        }
    }

    @MainActor private func editInComposer() {
        actions.editInComposer(DiffPromptFormatter().format(target: target, note: note))
        dismiss()
        dismissViewer()
    }

    private var title: String {
        DiffLocalized().string("diff.quickNote.title", defaultValue: "Send to Agent")
    }

    private var previewLabel: String {
        DiffLocalized().string("diff.quickNote.preview", defaultValue: "Excerpt preview")
    }

    private var noteLabel: String {
        DiffLocalized().string("diff.quickNote.note", defaultValue: "Note")
    }

    private var notePlaceholder: String {
        DiffLocalized().string("diff.quickNote.notePlaceholder", defaultValue: "What should the agent inspect or change?")
    }

    private var sendLabel: String {
        DiffLocalized().string("diff.quickNote.send", defaultValue: "Send")
    }

    private var editLabel: String {
        DiffLocalized().string("diff.quickNote.editInComposer", defaultValue: "Edit in composer")
    }

    private var cancelLabel: String {
        DiffLocalized().string("diff.action.cancel", defaultValue: "Cancel")
    }

    private var unavailableHint: String {
        DiffLocalized().string(
            "diff.quickNote.unavailable",
            defaultValue: "Start an agent chat session in this workspace to send a diff note."
        )
    }
}
