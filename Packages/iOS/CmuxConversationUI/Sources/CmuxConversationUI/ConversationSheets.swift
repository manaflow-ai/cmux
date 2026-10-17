#if os(iOS)
import CmuxConversation
import SwiftUI

struct ConversationNewTaskSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ConversationModel
    @State private var provider: ConversationProvider = .codex
    @State private var workspaceID: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(ConversationL10n.value("conversation.provider", "Provider")) {
                    Picker(ConversationL10n.value("conversation.provider", "Provider"), selection: $provider) {
                        ForEach([ConversationProvider.codex, .claudeCode, .openCode], id: \.self) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("ConversationProviderPicker")
                }
                Section(ConversationL10n.value("conversation.workspace", "Workspace")) {
                    if model.workspaces.isEmpty {
                        ContentUnavailableView(ConversationL10n.value("conversation.no_workspaces", "No workspaces"), systemImage: "folder", description: Text(ConversationL10n.value("conversation.choose_workspace", "Choose a connected workspace before starting a task.")))
                    } else {
                        ForEach(model.workspaces) { workspace in
                            Button {
                                workspaceID = workspace.id
                            } label: {
                                HStack {
                                    Image(systemName: workspaceID == workspace.id ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(workspaceID == workspace.id ? .blue : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(workspace.title).foregroundStyle(.primary)
                                        Text(workspace.directory).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("ConversationWorkspace-\(workspace.id)")
                        }
                    }
                }
            }
            .navigationTitle(ConversationL10n.value("conversation.new_task", "New task"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(ConversationL10n.value("conversation.cancel", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(ConversationL10n.value("conversation.start", "Start")) {
                        model.createSession(provider: provider, workspace: model.workspaces.first(where: { $0.id == workspaceID }))
                        dismiss()
                    }
                    .disabled(workspaceID == nil || model.isSubmitting)
                }
            }
            .task {
                provider = model.newTaskProvider
                workspaceID = model.newTaskWorkspace?.id ?? model.workspaces.first?.id
            }
        }
        // File browsing needs the full sheet height so the last changed-file
        // row remains a real hit target on both iPhone and iPad.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("ConversationNewTaskSheet")
    }
}

struct ConversationModelSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ConversationModel
    @State private var selectedModel = ""
    @State private var effort = ""
    @State private var speed = ""

    private var capabilities: ConversationCapabilities? { model.capabilities }

    var body: some View {
        NavigationStack {
            Form {
                if let capabilities, !capabilities.models.isEmpty {
                    Section(ConversationL10n.value("conversation.model", "Model")) {
                        Picker(ConversationL10n.value("conversation.model", "Model"), selection: $selectedModel) {
                            Text(ConversationL10n.value("conversation.provider_default", "Provider default")).tag("")
                            ForEach(capabilities.models, id: \.self) { value in Text(value).tag(value) }
                        }
                        .accessibilityIdentifier("ConversationModelPicker")
                    }
                }
                if capabilities?.efforts.isEmpty == false || capabilities?.speeds.isEmpty == false {
                  Section(ConversationL10n.value("conversation.intelligence", "Intelligence")) {
                    if let capabilities, !capabilities.efforts.isEmpty {
                        Picker(ConversationL10n.value("conversation.effort", "Effort"), selection: $effort) {
                            Text(ConversationL10n.value("conversation.provider_default", "Provider default")).tag("")
                            ForEach(capabilities.efforts, id: \.self) { value in Text(value.capitalized).tag(value) }
                        }
                        .accessibilityIdentifier("ConversationEffortPicker")
                    }
                    if let capabilities, !capabilities.speeds.isEmpty {
                        Picker(ConversationL10n.value("conversation.speed", "Speed"), selection: $speed) {
                            Text(ConversationL10n.value("conversation.provider_default", "Provider default")).tag("")
                            ForEach(capabilities.speeds, id: \.self) { value in Text(value.capitalized).tag(value) }
                        }
                        .accessibilityIdentifier("ConversationSpeedPicker")
                    }
                  }
                }
                Text(ConversationL10n.value("conversation.settings_next_message", "Changes apply to your next message."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle(ConversationL10n.value("conversation.model_effort", "Model and effort"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let session = model.sessions.first(where: { $0.id == model.selectedSessionID })
                        if selectedModel != (session?.model ?? "") || effort != (session?.effort ?? "") || speed != (session?.speed ?? "") {
                            model.configure(model: selectedModel.isEmpty ? nil : selectedModel, effort: effort.isEmpty ? nil : effort, speed: speed.isEmpty ? nil : speed)
                        }
                        dismiss()
                    } label: {
                        Text(ConversationL10n.value("conversation.done", "Done"))
                    }
                    .accessibilityIdentifier("ConversationSettingsDone")
                    // A toolbar item adds an accessibility wrapper around its
                    // Button.  Apply the identifier before collapsing the
                    // children so iPadOS keeps only one exact match, matching
                    // the working toolbar pattern used by the task list.
                    .accessibilityElement(children: .ignore)
                }
            }
            .task {
                let session = model.sessions.first(where: { $0.id == model.selectedSessionID })
                selectedModel = session?.model ?? ""
                effort = session?.effort ?? ""
                speed = session?.speed ?? ""
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("ConversationModelSettings")
    }
}

struct ConversationFilesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let items: [ConversationItem]
    let capabilities: ConversationCapabilities?
    @State private var selection: ConversationItemID?
    @State private var filter = DiffFilter.all

    private enum DiffFilter: String, CaseIterable, Identifiable {
        case all
        case unstaged
        case staged
        case lastTurn = "last-turn"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: ConversationL10n.value("conversation.all", "All")
            case .unstaged: ConversationL10n.value("conversation.unstaged", "Unstaged")
            case .staged: ConversationL10n.value("conversation.staged", "Staged")
            case .lastTurn: ConversationL10n.value("conversation.last_turn", "Last turn")
            }
        }
    }

    private var diffs: [(id: ConversationItemID, diff: ConversationDiff)] {
        items.compactMap { item in
            guard let diff = item.diff else { return nil }
            guard filter == .all || diff.comparison.lowercased() == filter.rawValue else { return nil }
            return (item.id, diff)
        }
    }

    private var visibleFilters: [DiffFilter] {
        DiffFilter.allCases.filter { filter in
            filter == .all
                || items.contains { $0.diff?.comparison.lowercased() == filter.rawValue }
                || (filter == .staged && capabilities?.features.contains("git_staged") == true)
                || (filter == .unstaged && capabilities?.features.contains("git_unstaged") == true)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker(ConversationL10n.value("conversation.comparison", "Comparison"), selection: $filter) {
                    ForEach(visibleFilters) { value in Text(value.title).tag(value) }
                }
                .pickerStyle(.segmented)
                if diffs.isEmpty {
                    ContentUnavailableView(ConversationL10n.value("conversation.no_changes", "No changes"), systemImage: "doc.text", description: Text(ConversationL10n.value("conversation.no_changes.description", "There are no changes for this comparison.")))
                        .accessibilityIdentifier("ConversationFilesEmptyState")
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(diffs, id: \.id) { entry in
                        Button {
                            selection = entry.id
                        } label: {
                            HStack {
                                Image(systemName: "doc.text")
                                Text(diffTitle(entry.diff))
                                Spacer()
                                Text(entry.diff.comparison).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(ConversationL10n.value("conversation.files", "Files"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(ConversationL10n.value("conversation.close", "Close")) { dismiss() } }
            }
            .sheet(item: Binding(get: {
                selection.flatMap { id in diffs.first(where: { $0.id == id }).map { ConversationDiffItem(id: id, diff: $0.diff) } }
            }, set: { value in selection = value?.id })) { item in
                NavigationStack {
                    ConversationDiffView(diff: item.diff)
                        .navigationTitle(diffTitle(item.diff))
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ConversationL10n.value("conversation.close", "Close")) { selection = nil } } }
                }
            }
        }
        // File browsing needs the full sheet height so the final changed-file
        // row remains a real hit target on both iPhone and iPad.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("ConversationFilesSheet")
    }

    private func diffTitle(_ diff: ConversationDiff) -> String {
        diff.path.isEmpty ? ConversationL10n.value("conversation.task_changes", "Task changes") : diff.path
    }
}

private struct ConversationDiffItem: Identifiable {
    let id: ConversationItemID
    let diff: ConversationDiff
}

/// A small native diff viewer with line numbers and colored additions/removals.
public struct ConversationDiffView: View {
    public let diff: ConversationDiff

    public init(diff: ConversationDiff) { self.diff = diff }

    public var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { index, line in
                    let value = String(line)
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 34, alignment: .trailing)
                        Text(value.isEmpty ? " " : value)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(lineColor(value))
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 8)
                    .background(lineBackground(value))
                }
            }
            .padding(.vertical, 8)
        }
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityIdentifier("ConversationDiffView-\(diff.path)")
    }

    private func lineColor(_ line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red }
        return .primary
    }

    private func lineBackground(_ line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green.opacity(0.11) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red.opacity(0.11) }
        return .clear
    }
}

/// Displays a file with selectable monospaced content and line numbers.
public struct ConversationFileView: View {
    public let name: String
    public let path: String
    public let content: String

    public init(name: String, path: String, content: String) {
        self.name = name; self.path = path; self.content = content
    }

    public var body: some View {
        ScrollView([.vertical, .horizontal]) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(Array(content.split(separator: "\n", omittingEmptySubsequences: false).indices), id: \.self) { index in
                        Text("\(index + 1)")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(content.isEmpty ? " " : content)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("ConversationFileView-\(path)")
    }
}

/// Renders plain text using the same native text selection and dynamic type.
public struct ConversationMarkdownView: View {
    public let text: String

    public init(text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#endif
