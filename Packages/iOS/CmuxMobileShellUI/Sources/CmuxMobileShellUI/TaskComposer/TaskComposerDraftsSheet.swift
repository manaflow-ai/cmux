#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// The saved, unsent drafts a user can return to. The active composer
/// session is not listed; resuming a row replaces that session after its
/// content is saved as a draft of its own.
struct TaskComposerDraftsSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Live source of the listed drafts. The sheet loads on its own appear
    /// instead of receiving a snapshot: a snapshot captured across the
    /// composer's draft-switch identity swap can be stale or empty.
    let loadDrafts: () -> [MobileTaskComposerSavedDraft]
    let templates: [MobileTaskTemplate]
    let resume: (UUID) -> Void
    let startNew: () -> Void
    let delete: (Set<UUID>) -> Void

    @State private var drafts: [MobileTaskComposerSavedDraft] = []

    var body: some View {
        NavigationStack {
            Group {
                if drafts.isEmpty {
                    ContentUnavailableView {
                        Label(
                            L10n.string(
                                "mobile.taskComposer.drafts.empty.title",
                                defaultValue: "No Other Drafts"
                            ),
                            systemImage: "tray"
                        )
                    } description: {
                        Text(L10n.string(
                            "mobile.taskComposer.drafts.empty.description",
                            defaultValue: "Leave the composer with an unsent task and it is saved here."
                        ))
                    }
                } else {
                    List {
                        ForEach(drafts) { draft in
                            Button {
                                resume(draft.id)
                            } label: {
                                TaskComposerDraftRow(
                                    draft: draft,
                                    templateName: templateName(for: draft)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("MobileTaskComposerDraftRow")
                        }
                        .onDelete { offsets in
                            let ids = Set(offsets.map { drafts[$0].id })
                            delete(ids)
                            drafts.removeAll { ids.contains($0.id) }
                        }
                    }
                    .accessibilityIdentifier("MobileTaskComposerDraftsList")
                }
            }
            .onAppear { drafts = loadDrafts() }
            .navigationTitle(L10n.string(
                "mobile.taskComposer.drafts.title",
                defaultValue: "Drafts"
            ))
            .mobileInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: startNew) {
                        Label(
                            L10n.string(
                                "mobile.taskComposer.drafts.new",
                                defaultValue: "New Draft"
                            ),
                            systemImage: "plus"
                        )
                    }
                    .accessibilityIdentifier("MobileTaskComposerNewDraftButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.common.done", defaultValue: "Done")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("MobileTaskComposerDraftsDoneButton")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func templateName(for draft: MobileTaskComposerSavedDraft) -> String? {
        draft.content.templateID.flatMap { id in
            templates.first { $0.id == id }?.name
        }
    }
}

private struct TaskComposerDraftRow: View {
    let draft: MobileTaskComposerSavedDraft
    let templateName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(hasPrompt ? Color.primary : Color.secondary)
                Spacer(minLength: 8)
                Text(draft.updatedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
            }
            if !subtitle.isEmpty || !draft.content.attachments.isEmpty {
                HStack(spacing: 6) {
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .lineLimit(1)
                    }
                    if !draft.content.attachments.isEmpty {
                        Label(
                            "\(draft.content.attachments.count)",
                            systemImage: "paperclip"
                        )
                        .labelStyle(.titleAndIcon)
                        .layoutPriority(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var hasPrompt: Bool {
        !draft.content.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var title: String {
        let workspaceName = (draft.content.workspaceName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let promptLine = draft.content.prompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first ?? ""
        if !promptLine.isEmpty {
            return promptLine
        }
        if !workspaceName.isEmpty {
            return workspaceName
        }
        return L10n.string(
            "mobile.taskComposer.drafts.untitled",
            defaultValue: "No prompt yet"
        )
    }

    private var subtitle: String {
        var parts: [String] = []
        if let templateName, !templateName.isEmpty {
            parts.append(templateName)
        }
        let directory = draft.content.directory
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !directory.isEmpty {
            parts.append(TaskComposerDirectoryDisplayPath(path: directory).name)
        }
        return parts.joined(separator: " · ")
    }
}
#endif
