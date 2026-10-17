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
                Section("Provider") {
                    Picker("Provider", selection: $provider) {
                        ForEach([ConversationProvider.codex, .claudeCode, .openCode], id: \.self) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("ConversationProviderPicker")
                }
                Section("Workspace") {
                    if model.workspaces.isEmpty {
                        ContentUnavailableView("No workspaces", systemImage: "folder", description: Text("Choose a connected workspace before starting a task."))
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
            .navigationTitle("New task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
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
    @State private var effort = "balanced"
    @State private var speed = "standard"

    var body: some View {
        NavigationStack {
            Form {
                Section("Intelligence") {
                    Picker("Effort", selection: $effort) {
                        Text("Fast").tag("fast")
                        Text("Balanced").tag("balanced")
                        Text("Thorough").tag("thorough")
                    }
                    Picker("Speed", selection: $speed) {
                        Text("Standard").tag("standard")
                        Text("Quick").tag("quick")
                    }
                }
                Text("These controls follow the capabilities advertised by the connected provider.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Model and effort")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
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
    @State private var filter = "Unstaged"

    private var diffs: [ConversationDiff] {
        items.compactMap(\.diff).filter { filter == "All" || $0.comparison.localizedCaseInsensitiveContains(filter.lowercased()) }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Comparison", selection: $filter) {
                    Text("Unstaged").tag("Unstaged")
                    Text("Staged").tag("Staged")
                    Text("Last turn").tag("Last turn")
                    Text("All").tag("All")
                }
                .pickerStyle(.segmented)
                if diffs.isEmpty {
                    ContentUnavailableView("No changes", systemImage: "doc.text", description: Text("There are no changes for this comparison."))
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
            .navigationTitle("Files")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .sheet(item: Binding(get: {
                selection.flatMap { path in diffs.first(where: { $0.path == path }).map { ConversationDiffItem(diff: $0) } }
            }, set: { value in selection = value?.diff.path })) { item in
                NavigationStack {
                    ConversationDiffView(diff: item.diff)
                        .navigationTitle(item.diff.path)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { selection = nil } } }
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
