import CmuxAgentChat
import CmuxMobileShell
import SwiftUI

/// The recent-chat list and its ChatGPT-style root toolbar.
struct MobileChatsListView: View {
    let sessions: [ChatSessionDescriptor]
    let previewText: (String) -> String?
    let isLoading: Bool
    let errorMessage: String?
    let isRestoringStoredMac: Bool
    let computerName: String
    let pendingLaunch: MobileChatLaunchRequest?
    let onSelect: (String) -> Void
    let onNewChat: () -> Void
    let onMenu: () -> Void
    let onComputers: () -> Void
    let onAddDevice: (() -> Void)?
    let onRetry: () -> Void

    var body: some View {
        Group {
            if isRestoringStoredMac && sessions.isEmpty {
                MobileChatConnectionPlaceholder(onRetry: onRetry)
            } else if isLoading && sessions.isEmpty {
                ProgressView("Loading chats…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sessions.isEmpty {
                MobileChatEmptyState(onNewChat: onNewChat, onAddDevice: onAddDevice, onRetry: onRetry)
            } else {
                List {
                    if let pendingLaunch {
                        MobileChatLaunchRow(provider: pendingLaunch.provider)
                            .listRowInsets(EdgeInsets(top: 12, leading: 18, bottom: 4, trailing: 18))
                            .listRowSeparator(.hidden)
                    }
                    Section {
                        ForEach(sessions) { session in
                            MobileChatSessionRow(
                                session: session,
                                previewText: previewText(session.id)
                            ) {
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
                        Button(action: onRetry) {
                            MobileChatInlineError(message: errorMessage)
                        }
                        .buttonStyle(.plain)
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
                Button(action: onMenu) {
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

private struct MobileChatLaunchRow: View {
    let provider: MobileChatProvider

    var body: some View {
        HStack(spacing: 11) {
            ProgressView()
                .controlSize(.small)
            Text("Starting \(provider.title) chat…")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("MobileChatStarting")
    }
}

private struct MobileChatSessionRow: View {
    let session: ChatSessionDescriptor
    let previewText: String?
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
                        if let previewText, !previewText.isEmpty {
                            Text(previewText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
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
    var size: CGFloat = 42

    var body: some View {
        TaskTemplateIcon(value: "agent:\(provider.rawValue)", size: size * 0.62)
            .frame(width: size, height: size)
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
