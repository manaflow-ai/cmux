import CmuxConversationCore
import CmuxConversationUI
import CmuxMobileShell
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The classic iOS entry point for the Mac Chief conversation list.
struct ChiefHomeView: View {
    let client: MobileChiefClient
    @Environment(\.dismiss) private var dismiss
    @State private var conversations: [MobileChiefConversation] = []
    @State private var selectedConversation: MobileChiefConversation?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && conversations.isEmpty {
                    ProgressView("Loading Chief")
                } else if let errorMessage, conversations.isEmpty {
                    ContentUnavailableView(
                        "Chief unavailable",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text(errorMessage)
                    )
                } else if conversations.isEmpty {
                    ContentUnavailableView(
                        "No Chief conversations",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Start a conversation from Chief on your Mac.")
                    )
                } else {
                    List(conversations) { conversation in
                        Button {
                            selectedConversation = conversation
                        } label: {
                            ChiefConversationRow(conversation: conversation)
                        }
                        .buttonStyle(.plain)
                    }
                    .refreshable { await load() }
                }
            }
            .navigationTitle("Chief")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
            .sheet(item: $selectedConversation) { conversation in
                ChiefConversationControllerRepresentable(
                    client: client,
                    conversation: conversation
                )
                .ignoresSafeArea(.container, edges: .bottom)
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            var rows = try await client.conversations()
            if rows.isEmpty {
                let status = try? await client.status()
                if let id = status?.defaultConversation, !id.isEmpty {
                    rows = [MobileChiefConversation(id: id, title: "Chief")]
                }
            }
            conversations = rows
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }
}

private struct ChiefConversationRow: View {
    let conversation: MobileChiefConversation

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: conversation.working ? "bolt.horizontal.circle.fill" : "bubble.left.fill")
                .font(.title3)
                .foregroundStyle(conversation.working ? .orange : .blue)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(conversation.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if conversation.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if conversation.unread > 0 {
                        Text("\(conversation.unread)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.blue, in: Capsule())
                    }
                }
                Text(conversation.preview.isEmpty ? "No messages yet" : conversation.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

#if canImport(UIKit)
private struct ChiefConversationControllerRepresentable: UIViewControllerRepresentable {
    let client: MobileChiefClient
    let conversation: MobileChiefConversation

    func makeCoordinator() -> Coordinator { Coordinator(client: client, conversationID: conversation.id) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let backend = ChiefConversationBackend(
            client: client,
            conversationID: conversation.id,
            title: conversation.title
        )
        let store = ConversationStore(backend: backend)
        context.coordinator.store = store
        let controller = ConversationViewController(
            store: store,
            options: ConversationPresentationOptions(
                placeholder: "Message Chief",
                serviceTitle: conversation.title,
                serviceSubtitle: "Mac Chief",
                unreadCount: conversation.unread,
                trailingSymbol: "bolt.horizontal"
            )
        )
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .pageSheet
        controller.onBack = { [weak navigation] in
            navigation?.dismiss(animated: true)
        }
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Stop",
            style: .plain,
            target: context.coordinator,
            action: #selector(Coordinator.stop)
        )
        store.start()
        return navigation
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: UINavigationController, coordinator: Coordinator) {
        coordinator.store?.stop()
    }

    final class Coordinator: NSObject {
        let client: MobileChiefClient
        let conversationID: String
        var store: ConversationStore?

        init(client: MobileChiefClient, conversationID: String) {
            self.client = client
            self.conversationID = conversationID
        }

        @objc func stop() {
            Task { _ = try? await client.stop(conversation: conversationID) }
        }
    }
}
#endif
