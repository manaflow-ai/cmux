#if os(iOS)
import CmuxAgentBrands
import CmuxMobileDesign
import CmuxMobileModel
import CmuxSpinner
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// Task Options (classic's): the workspace's name card, then where it runs (Mac and folder),
/// and with several agents the workspace each one gets.
struct TaskComposerOptionsSheet: View {
    @Bindable var creator: WorkspaceCreator
    let sameNames: MacNameDisambiguation
    /// What Start sent (the screen is closing): shown, never edited.
    let sent: TaskDraft?
    let blocker: TaskStartBlocker?
    @Environment(\.dismiss) private var dismiss

    private var draft: TaskDraft { sent ?? creator.taskDraft }
    private var mac: MacDevice? { creator.taskMac(for: draft) }
    private var folders: [String] { mac.map { creator.taskFolders(on: $0.id) } ?? [] }
    private var folder: String? { mac.flatMap { creator.taskFolder(for: draft, on: $0.id) } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    nameCard
                    routeCard
                    if draft.picks.count > 1 { titles }
                    if let blocker, blocker == .noFolder || blocker == .noMac {
                        Text(blocker.message)
                            .font(theme.type.meta)
                            .foregroundStyle(theme.colors.warning.color)
                            .padding(.horizontal, 16)
                            .accessibilityIdentifier("taskComposer.blocker.options")
                    }
                }
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Task Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("taskComposer.options.done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Workspace name (optional)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(theme.colors.label2.color)
            TextField(draft.trimmedPrompt.isEmpty ? "Generated from prompt" : draft.title, text: Binding(
                get: { draft.name }, set: { if sent == nil { creator.taskDraft.name = $0 } }
            ))
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .accessibilityLabel("Workspace name")
            .accessibilityIdentifier("taskComposer.name")
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(card, in: cardShape)
    }

    private var routeCard: some View {
        VStack(spacing: 0) {
            macRow
            Divider().padding(.leading, 58)
            folderRow
        }
        .padding(.vertical, 4)
        .background(card, in: cardShape)
    }

    @ViewBuilder private var macRow: some View {
        let macs = creator.taskMacs
        if macs.count > 1, let mac {
            Menu {
                Picker("Mac", selection: Binding(get: { mac.id }, set: { if sent == nil { creator.taskDraft.chooseMac($0) } })) {
                    ForEach(macs) { Text(sameNames.displayName($0)).tag($0.id) }
                }
            } label: {
                routeLabel(symbol: "desktopcomputer", title: "Mac", value: sameNames.displayName(mac), chevron: "chevron.up.chevron.down")
            }
            .accessibilityLabel("Mac")
            .accessibilityValue(sameNames.displayName(mac))
            .accessibilityIdentifier("taskComposer.mac")
        } else {
            routeLabel(symbol: "desktopcomputer", title: "Mac", value: mac.map { sameNames.displayName($0) } ?? "No Mac online", chevron: nil)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("taskComposer.mac.only")
        }
    }

    @ViewBuilder private var folderRow: some View {
        if folders.isEmpty {
            routeLabel(symbol: "folder.fill", title: "Folder", value: "None open on this Mac", chevron: nil)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("taskComposer.folder.none")
        } else {
            Menu {
                Picker("Folder", selection: Binding(get: { folder ?? "" }, set: { if sent == nil { creator.taskDraft.directory = $0 } })) {
                    ForEach(folders, id: \.self) { directory in
                        Text(NewWorkspaceButton.folderName(directory)).tag(directory)
                    }
                }
            } label: {
                routeLabel(symbol: "folder.fill", title: "Folder", value: folder ?? "", chevron: "chevron.up.chevron.down", path: true)
            }
            .accessibilityLabel("Folder")
            .accessibilityValue(folder ?? "")
            .accessibilityIdentifier("taskComposer.folder")
        }
    }

    /// Classic's route row: a tinted symbol tile, the field's name over its value.
    private func routeLabel(symbol: String, title: String, value: String, chevron: String?, path: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(theme.colors.accent.color)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(theme.colors.label2.color)
                Text(value)
                    .font(path ? .system(.caption, design: .monospaced, weight: .semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(theme.colors.label.color)
                    .lineLimit(1)
                    .truncationMode(path ? .middle : .tail)
            }
            Spacer(minLength: 0)
            if let chevron {
                Image(systemName: chevron)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.colors.label3.color)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(.rect)
    }

    /// With several agents, one workspace each: what each is called.
    private var titles: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Workspaces")
                .font(.caption2.weight(.medium))
                .foregroundStyle(theme.colors.label2.color)
            ForEach(draft.picks) { pick in
                Text("\(pick.name ?? WorkspaceCreator.agentTitle(pick.harness)) · \(draft.title)")
                    .font(.subheadline)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card, in: cardShape)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("taskComposer.titles")
    }

    private var card: Color { Color(uiColor: .secondarySystemGroupedBackground) }
    private var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }
}

/// Drafts (classic's): the saved, unsent tasks but the one the composer holds. A row opens its
/// draft in the composer (the one it held is saved first); swipe to delete; New Draft saves the
/// one held and starts an empty one.
struct TaskComposerDraftsSheet: View {
    @Bindable var creator: WorkspaceCreator
    let macName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                let drafts = creator.otherTaskDrafts
                if !creator.taskDrafts.isLoaded {
                    CmuxSpinner(label: Text("Loading drafts…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if drafts.isEmpty {
                    ContentUnavailableView {
                        Label("No Other Drafts", systemImage: "tray")
                    } description: {
                        Text("Leave New Task with a task you haven't started and it's saved here.")
                    }
                    .accessibilityIdentifier("taskComposer.drafts.empty")
                } else {
                    List {
                        ForEach(drafts) { draft in
                            Button {
                                Task {
                                    await creator.resumeTaskDraft(draft.id)
                                    dismiss()
                                }
                            } label: {
                                TaskComposerDraftRow(draft: draft)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("taskComposer.draftRow")
                        }
                        .onDelete { offsets in
                            creator.taskDrafts.delete(Set(offsets.map { drafts[$0].id }))
                        }
                    }
                    .accessibilityIdentifier("taskComposer.draftsList")
                }
            }
            .navigationTitle("Drafts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        creator.newTaskDraft()
                        dismiss()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New Draft")
                    .disabled(creator.taskDraft.isEmpty)
                    .accessibilityIdentifier("taskComposer.newDraft")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("taskComposer.drafts.done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// A draft's row: its prompt's first line and when it was saved, then its agents, folder and
/// photo count.
struct TaskComposerDraftRow: View {
    let draft: SavedTaskDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(draft.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(draft.hasPrompt ? theme.colors.label.color : theme.colors.label2.color)
                Spacer(minLength: 8)
                Text(draft.updatedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(theme.colors.label2.color)
                    .layoutPriority(1)
            }
            if !subtitle.isEmpty || !draft.imageIDs.isEmpty {
                HStack(spacing: 6) {
                    if !subtitle.isEmpty { Text(subtitle).lineLimit(1) }
                    if !draft.imageIDs.isEmpty {
                        Label("\(draft.imageIDs.count)", systemImage: "photo")
                            .labelStyle(.titleAndIcon)
                            .layoutPriority(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(theme.colors.label2.color)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts = draft.picks.map { $0.name ?? WorkspaceCreator.agentTitle($0.harness) }
        if let directory = draft.directory, !directory.isEmpty { parts.append(NewWorkspaceButton.folderName(directory)) }
        return parts.joined(separator: " · ")
    }
}
#endif
