import CmuxAgentChat
import SwiftUI

/// A compact activity view for users who want a cross-agent status glance.
struct MobileChatActivityView: View {
    let sessions: [ChatSessionDescriptor]
    let onNewChat: () -> Void

    var body: some View {
        List {
            Section {
                ForEach(sessions) { session in
                    if let provider = MobileChatProvider.resolve(session.agentKind) {
                        HStack(spacing: 12) {
                            MobileChatProviderBadge(provider: provider)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.title?.isEmpty == false ? session.title! : "Untitled chat")
                                    .font(.body.weight(.medium))
                                Text(session.state.displayName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            MobileChatStateDot(state: session.state)
                        }
                        .padding(.vertical, 5)
                        .listRowSeparator(.hidden)
                    }
                }
            } header: {
                Text("Agent activity")
                    .font(.subheadline.weight(.semibold))
                    .textCase(nil)
            }
        }
        .listStyle(.plain)
        .overlay {
            if sessions.isEmpty {
                ContentUnavailableView(
                    "Nothing running",
                    systemImage: "moon.zzz",
                    description: Text("Start a chat to see agent activity here.")
                )
            }
        }
        .navigationTitle("Activity")
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
}
