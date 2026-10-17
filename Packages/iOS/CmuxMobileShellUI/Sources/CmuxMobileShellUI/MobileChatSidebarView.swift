import CmuxAgentChat
import SwiftUI

/// The ChatGPT-style account drawer: search, new chat, activity, and recent
/// conversations live in one place instead of competing with the transcript
/// at the bottom of the screen.
struct MobileChatSidebarView: View {
    let sessions: [ChatSessionDescriptor]
    let previewText: (String) -> String?
    let computerName: String
    let onSelect: (String) -> Void
    let onNewChat: () -> Void
    let onActivity: () -> Void
    let onSettings: () -> Void
    let onComputers: () -> Void
    let onSignOut: @MainActor @Sendable () -> Void

    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: onNewChat) {
                        Label("New chat", systemImage: "square.and.pencil")
                    }
                    .accessibilityIdentifier("MobileSidebarNewChat")

                    Button(action: onActivity) {
                        Label("Activity", systemImage: "clock.arrow.circlepath")
                    }
                    .accessibilityIdentifier("MobileSidebarActivity")
                }

                Section {
                    ForEach(filteredSessions) { session in
                        MobileChatSidebarRow(
                            session: session,
                            previewText: previewText(session.id),
                            onSelect: { onSelect(session.id) }
                        )
                    }
                } header: {
                    Text("Recent")
                }

                Section {
                    Button(action: onComputers) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Computer")
                                Text(computerName.isEmpty ? "Choose a computer" : computerName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "desktopcomputer")
                        }
                    }
                    .accessibilityIdentifier("MobileSidebarComputer")

                    Button(action: onSettings) {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("MobileSidebarSettings")

                    Button(action: onSignOut) {
                        Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .accessibilityIdentifier("MobileSidebarSignOut")
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search chats")
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onNewChat) {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New chat")
                }
            }
        }
        .accessibilityIdentifier("MobileChatSidebar")
    }

    private var filteredSessions: [ChatSessionDescriptor] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return sessions }
        return sessions.filter { session in
            let title = session.title?.lowercased() ?? ""
            let provider = MobileChatProvider.resolve(session.agentKind)?.title.lowercased() ?? ""
            return title.contains(normalizedQuery) || provider.contains(normalizedQuery)
        }
    }
}

private struct MobileChatSidebarRow: View {
    let session: ChatSessionDescriptor
    let previewText: String?
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                if let provider = MobileChatProvider.resolve(session.agentKind) {
                    MobileChatProviderBadge(provider: provider, size: 30)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title?.isEmpty == false ? session.title! : "Untitled chat")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if let previewText, !previewText.isEmpty {
                        Text(previewText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                MobileChatStateDot(state: session.state)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("MobileChatSidebarSession-\(session.id)")
    }
}
