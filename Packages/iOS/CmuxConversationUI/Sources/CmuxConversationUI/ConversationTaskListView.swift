#if os(iOS)
import CmuxConversation
import SwiftUI

struct ConversationTaskListView: View {
    @Bindable var model: ConversationModel
    let onNewTask: () -> Void
    @State private var editingSession: ConversationSession?
    @State private var renameText = ""
    @State private var showsArchiveConfirmation = false
    @State private var archiveTarget: ConversationSession?

    var body: some View {
        List {
            if model.connectionState != .connected {
                Section {
                    ConversationConnectionBanner(state: model.connectionState)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            let pinned = model.filteredSessions.filter(\.isPinned)
            let recent = model.filteredSessions.filter { !$0.isPinned }
            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned) { sessionRow($0) }
                }
                .accessibilityIdentifier("ConversationPinnedSection")
            }
            Section(pinned.isEmpty ? "Tasks" : "Recent") {
                if recent.isEmpty && pinned.isEmpty {
                    ContentUnavailableView(
                        "No tasks yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Start a task to work with Codex, Claude Code, or OpenCode.")
                    )
                    .accessibilityIdentifier("ConversationEmptyState")
                } else {
                    ForEach(recent) { sessionRow($0) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $model.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search tasks")
        .navigationTitle("Tasks")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onNewTask) {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New task")
                .accessibilityIdentifier("ConversationNewTaskButton")
            }
        }
        .refreshable { model.refreshSessions() }
        .sheet(item: $editingSession) { session in
            NavigationStack {
                Form {
                    TextField("Task name", text: $renameText)
                        .textInputAutocapitalization(.sentences)
                        .accessibilityIdentifier("ConversationRenameField")
                }
                .navigationTitle("Rename task")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editingSession = nil } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !title.isEmpty { model.renameSession(session, title: title) }
                            editingSession = nil
                        }
                    }
                }
            }
            .presentationDetents([.height(180)])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog("Archive task?", isPresented: $showsArchiveConfirmation, titleVisibility: .visible) {
            Button("Archive", role: .destructive) {
                if let archiveTarget { model.archive(archiveTarget) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the task from the remote task list.")
        }
        .accessibilityIdentifier("ConversationTaskList")
    }

    @ViewBuilder
    private func sessionRow(_ session: ConversationSession) -> some View {
        Button {
            model.selectSession(id: session.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: session.provider == .codex ? "sparkles" : "bubble.left.and.bubble.right")
                    .font(.title3)
                    .foregroundStyle(.blue)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(session.title.isEmpty ? "Untitled task" : session.title)
                            .font(.body.weight(session.isUnread ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if session.isPinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
                        if session.state == .starting { ProgressView().controlSize(.mini) }
                    }
                    HStack(spacing: 5) {
                        Text(session.directory.isEmpty ? session.workspaceID : session.directory)
                        Text("·")
                        Text(session.provider.displayName)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                if session.isUnread { Circle().fill(.blue).frame(width: 8, height: 8) }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(session.isPinned ? "Unpin" : "Pin", systemImage: session.isPinned ? "pin.slash" : "pin") {
                model.setPinned(session, pinned: !session.isPinned)
            }
            Button("Rename", systemImage: "pencil") {
                renameText = session.title
                editingSession = session
            }
            Button("Mark unread", systemImage: "circle") {
                // The host owns unread persistence; selection remains local.
            }
            Divider()
            Button("Archive", systemImage: "archivebox", role: .destructive) {
                archiveTarget = session
                showsArchiveConfirmation = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ConversationTaskRow-\(session.id.rawValue)")
        .accessibilityLabel("\(session.title), \(session.provider.displayName)")
    }
}

private struct ConversationConnectionBanner: View {
    let state: ConversationConnectionState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
            VStack(alignment: .leading, spacing: 2) {
                Text(state == .connecting ? "Connecting" : "Cloud service unavailable")
                    .font(.subheadline.weight(.semibold))
                if case .failed(let message) = state { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
        }
        .padding(14)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("ConversationConnectionBanner")
    }
}

#endif
