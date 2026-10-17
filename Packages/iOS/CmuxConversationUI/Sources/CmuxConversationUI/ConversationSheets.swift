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
        .presentationDetents([.medium, .large])
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
                            ForEach(capabilities.models, id: \.self) { value in Text(value).tag(value) }
                        }
                    }
                }
                Section(ConversationL10n.value("conversation.intelligence", "Intelligence")) {
                    if let capabilities, !capabilities.efforts.isEmpty {
                        Picker(ConversationL10n.value("conversation.effort", "Effort"), selection: $effort) {
                            ForEach(capabilities.efforts, id: \.self) { value in Text(value.capitalized).tag(value) }
                        }
                    }
                    if let capabilities, !capabilities.speeds.isEmpty {
                        Picker(ConversationL10n.value("conversation.speed", "Speed"), selection: $speed) {
                            ForEach(capabilities.speeds, id: \.self) { value in Text(value.capitalized).tag(value) }
                        }
                    }
                }
                Text(ConversationL10n.value("conversation.capabilities", "These controls follow the capabilities advertised by the connected provider."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle(ConversationL10n.value("conversation.model_effort", "Model and effort"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(ConversationL10n.value("conversation.done", "Done")) {
                        model.configure(model: selectedModel.isEmpty ? nil : selectedModel, effort: effort.isEmpty ? nil : effort, speed: speed.isEmpty ? nil : speed)
                        dismiss()
                    }
                }
            }
            .task {
                let session = model.sessions.first(where: { $0.id == model.selectedSessionID })
                selectedModel = session?.model ?? capabilities?.models.first ?? ""
                effort = session?.effort ?? capabilities?.efforts.first ?? ""
                speed = session?.speed ?? capabilities?.speeds.first ?? ""
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
    @State private var selection: String?
    @State private var filter = ConversationL10n.value("conversation.unstaged", "Unstaged")

    private var diffs: [ConversationDiff] {
        items.compactMap(\.diff).filter { filter == ConversationL10n.value("conversation.all", "All") || $0.comparison.localizedCaseInsensitiveContains(filter.lowercased()) }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker(ConversationL10n.value("conversation.comparison", "Comparison"), selection: $filter) {
                    Text(ConversationL10n.value("conversation.unstaged", "Unstaged")).tag(ConversationL10n.value("conversation.unstaged", "Unstaged"))
                    Text(ConversationL10n.value("conversation.staged", "Staged")).tag(ConversationL10n.value("conversation.staged", "Staged"))
                    Text(ConversationL10n.value("conversation.last_turn", "Last turn")).tag(ConversationL10n.value("conversation.last_turn", "Last turn"))
                    Text(ConversationL10n.value("conversation.all", "All")).tag(ConversationL10n.value("conversation.all", "All"))
                }
                .pickerStyle(.segmented)
                if diffs.isEmpty {
                    ContentUnavailableView(ConversationL10n.value("conversation.no_changes", "No changes"), systemImage: "doc.text", description: Text(ConversationL10n.value("conversation.no_changes.description", "There are no changes for this comparison.")))
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(diffs, id: \.path) { diff in
                        Button {
                            selection = diff.path
                        } label: {
                            HStack {
                                Image(systemName: "doc.text")
                                Text(diff.path)
                                Spacer()
                                Text(diff.comparison).font(.caption).foregroundStyle(.secondary)
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
                selection.flatMap { path in diffs.first(where: { $0.path == path }).map { ConversationDiffItem(diff: $0) } }
            }, set: { value in selection = value?.diff.path })) { item in
                NavigationStack {
                    ConversationDiffView(diff: item.diff)
                        .navigationTitle(item.diff.path)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ConversationL10n.value("conversation.close", "Close")) { selection = nil } } }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("ConversationFilesSheet")
    }
}

private struct ConversationDiffItem: Identifiable {
    let diff: ConversationDiff
    var id: String { diff.path }
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
