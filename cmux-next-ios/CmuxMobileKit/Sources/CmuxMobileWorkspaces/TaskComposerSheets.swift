#if os(iOS)
import CmuxAgentBrands
import CmuxMobileDesign
import CmuxMobileModel
import CmuxSpinner
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// Task Options (classic's): the workspace's name, Chat or Terminal, then where it runs (a Mac
/// and its folder, or a Cloud machine).
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
    private var cloud: CloudTaskTarget? { creator.taskCloud(for: draft) }
    /// A Cloud machine is chosen (it may be unreachable now: the row still names the choice).
    private var onCloud: Bool { draft.cloudID != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    nameCard
                    if !onCloud { launchCard }
                    routeCard
                    if let blocker, [.noFolder, .noMac, .noCloud, .cloudTextOnly].contains(blocker) {
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
            .submitLabel(.done)
            .accessibilityLabel("Workspace name")
            .accessibilityIdentifier("taskComposer.name")
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(card, in: cardShape)
    }

    /// Where the task opens: the agent's chat, or its CLI in a terminal (the composer's
    /// subtitle says which; the next task starts on the same).
    private var launchCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Open in")
                .font(.caption2.weight(.medium))
                .foregroundStyle(theme.colors.label2.color)
            Picker("Open in", selection: Binding(get: { draft.launch }, set: { if sent == nil { creator.taskDraft.launch = $0 } })) {
                ForEach(TaskLaunch.allCases, id: \.self) { launch in
                    Label(launch.title, systemImage: launch.systemImage).tag(launch)
                }
            }
            .pickerStyle(.segmented)
            .disabled(sent != nil)
            .accessibilityIdentifier("taskComposer.launch")
            Text(draft.launch == .chat ? "The agent's chat, with its replies and approvals on this iPhone."
                                       : "The agent's command line in a terminal tab, as on the Mac.")
                .font(theme.type.meta)
                .foregroundStyle(theme.colors.label2.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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

    /// Where it runs: one of the Macs, or a Cloud machine (listed under its own heading).
    @ViewBuilder private var macRow: some View {
        let macs = creator.taskMacs
        let clouds = creator.cloudTaskTargets
        if macs.count > 1 || !clouds.isEmpty, let shown = placeName {
            TaskPlaceMenu(creator: creator, sameNames: sameNames, sent: sent) {
                routeLabel(symbol: onCloud ? "cloud" : "desktopcomputer", title: onCloud ? "Cloud machine" : "Mac", value: shown,
                           chevron: "chevron.up.chevron.down")
            }
            .accessibilityLabel(onCloud ? "Cloud machine" : "Mac")
            .accessibilityValue(shown)
            .accessibilityIdentifier("taskComposer.mac")
        } else {
            routeLabel(symbol: "desktopcomputer", title: "Mac", value: mac.map { sameNames.displayName($0) } ?? "No Mac online", chevron: nil)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("taskComposer.mac.only")
        }
    }

    /// The chosen place's name: the Cloud machine's, else the Mac's; nil with neither.
    private var placeName: String? {
        if onCloud { return cloud?.name ?? "Not reachable now" }
        return mac.map { sameNames.displayName($0) }
    }

    @ViewBuilder private var folderRow: some View {
        if onCloud {
            // The Cloud machine makes the chat's own folder (hostd's start takes no folder from a
            // phone, cloud_acp.rs), and runs Claude asking before it acts.
            routeLabel(symbol: "folder.fill", title: "Folder", value: "A new folder on the machine", chevron: nil)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("taskComposer.folder.cloud")
        } else if folders.isEmpty {
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
                    .font(.subheadline.weight(.semibold))
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
                            .buttonStyle(.cmuxPressFill)
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
            if !subtitle.isEmpty || !draft.imageIDs.isEmpty || !draft.files.isEmpty {
                HStack(spacing: 6) {
                    if !subtitle.isEmpty { Text(subtitle).lineLimit(1) }
                    if !draft.imageIDs.isEmpty {
                        Label("\(draft.imageIDs.count)", systemImage: "photo")
                            .labelStyle(.titleAndIcon)
                            .layoutPriority(1)
                    }
                    if !draft.files.isEmpty {
                        Label("\(draft.files.count)", systemImage: "doc")
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
        var parts = draft.picks.isEmpty ? ["Default agent"] : draft.picks.map { $0.name ?? WorkspaceCreator.agentTitle($0.harness) }
        parts.append(draft.launch.title)
        if let directory = draft.directory, !directory.isEmpty { parts.append(NewWorkspaceButton.folderName(directory)) }
        return parts.joined(separator: " · ")
    }
}
#endif

/// Where a task runs, as a menu: the Macs, then the Cloud machines under their own heading. Task
/// Options' Mac row and the composer's place pill open it.
struct TaskPlaceMenu<MenuLabel: View>: View {
    let creator: WorkspaceCreator
    let sameNames: MacNameDisambiguation
    let sent: TaskDraft?
    @ViewBuilder let label: () -> MenuLabel

    var body: some View {
        Menu {
            Picker("Runs on", selection: Binding(get: { tag }, set: { choose($0) })) {
                ForEach(creator.taskMacs) { Label(sameNames.displayName($0), systemImage: "desktopcomputer").tag("mac:" + $0.id) }
            }
            if !creator.cloudTaskTargets.isEmpty {
                Section("Cloud") {
                    Picker("Cloud", selection: Binding(get: { tag }, set: { choose($0) })) {
                        ForEach(creator.cloudTaskTargets) { Label($0.name, systemImage: "cloud").tag("cloud:" + $0.id) }
                    }
                }
            }
        } label: {
            label()
        }
    }

    private var tag: String {
        let draft = creator.taskDraft
        if let id = draft.cloudID { return "cloud:" + id }
        return creator.taskMac(for: draft).map { "mac:" + $0.id } ?? ""
    }

    private func choose(_ tag: String) {
        guard sent == nil else { return }
        if tag.hasPrefix("cloud:") {
            creator.taskDraft.chooseCloud(String(tag.dropFirst(6)))
        } else if tag.hasPrefix("mac:") {
            creator.taskDraft.chooseMac(String(tag.dropFirst(4)))
        }
    }
}
