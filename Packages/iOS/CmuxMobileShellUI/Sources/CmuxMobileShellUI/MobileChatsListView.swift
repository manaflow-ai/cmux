import CmuxAgentChat
import CmuxMobileShell
import SwiftUI

/// The recent-chat list and its ChatGPT-style root toolbar.
struct MobileChatsListView: View {
    let sessions: [ChatSessionDescriptor]
    let isLoading: Bool
    let errorMessage: String?
    let isRestoringStoredMac: Bool
    let computerName: String
    let onSelect: (String) -> Void
    let onNewChat: () -> Void
    let onSettings: () -> Void
    let onComputers: () -> Void
    let onAddDevice: (() -> Void)?

    var body: some View {
        Group {
            if isRestoringStoredMac && sessions.isEmpty {
                MobileChatConnectionPlaceholder()
            } else if isLoading && sessions.isEmpty {
                ProgressView("Loading chats…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sessions.isEmpty {
                MobileChatEmptyState(onNewChat: onNewChat, onAddDevice: onAddDevice)
            } else {
                List {
                    Section {
                        ForEach(sessions) { session in
                            MobileChatSessionRow(session: session) {
                                onSelect(session.id)
                            }
                            .listRowInsets(EdgeInsets(top: 8, leading: 18, bottom: 8, trailing: 18))
                            .listRowSeparator(.hidden)
                        }
                    } header: {
                        Text("Recent")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                            .padding(.top, 8)
                    }
                }
                .listStyle(.plain)
                .overlay(alignment: .bottom) {
                    if let errorMessage {
                        MobileChatInlineError(message: errorMessage)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                    }
                }
            }
        }
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button(action: onComputers) {
                        Label("Choose computer", systemImage: "desktopcomputer")
                    }
                    Button(action: onSettings) {
                        Label("Settings", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.body.weight(.semibold))
                        .frame(width: 34, height: 34)
                }
                .accessibilityLabel("Chat menu")
                .accessibilityIdentifier("MobileChatMenu")
            }
            ToolbarItem(placement: .principal) {
                Button(action: onComputers) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(.green)
                            .frame(width: 7, height: 7)
                        Text(computerName.isEmpty ? "Computer" : computerName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.thinMaterial, in: Capsule())
                }
                .accessibilityLabel("Computer")
                .accessibilityIdentifier("MobileChatComputerPicker")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onNewChat) {
                    Image(systemName: "square.and.pencil")
                        .font(.body.weight(.semibold))
                        .frame(width: 34, height: 34)
                }
                .accessibilityLabel("New chat")
                .accessibilityIdentifier("MobileChatNewChat")
            }
        }
    }
}

private struct MobileChatSessionRow: View {
    let session: ChatSessionDescriptor
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            if let provider = MobileChatProvider.resolve(session.agentKind) {
                HStack(spacing: 13) {
                    MobileChatProviderBadge(provider: provider)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(session.title?.isEmpty == false ? session.title! : "New \(provider.title) chat")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if let activity = session.lastActivityAt {
                                Text(activity, format: .relative(presentation: .named))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        HStack(spacing: 6) {
                            MobileChatStateDot(state: session.state)
                            Text(session.state.displayName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("MobileChatSession-\(session.id)")
    }
}

struct MobileChatProviderBadge: View {
    let provider: MobileChatProvider

    var body: some View {
        Image(systemName: provider.symbolName)
            .font(.body.weight(.semibold))
            .foregroundStyle(provider.tint)
            .frame(width: 42, height: 42)
            .background(provider.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

struct MobileChatStateDot: View {
    let state: ChatAgentState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch state {
        case .idle: .secondary
        case .working: .blue
        case .needsInput: .orange
        case .ended: .red
        }
    }
}

extension ChatAgentState {
    var displayName: String {
        switch self {
        case .idle: "Ready"
        case .working: "Working"
        case .needsInput: "Needs your input"
        case .ended: "Ended"
        }
    }
}
