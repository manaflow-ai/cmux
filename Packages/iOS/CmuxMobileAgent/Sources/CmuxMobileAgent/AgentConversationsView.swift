public import CmuxConversation
public import SwiftUI

/// The phone's agent conversations: the Mac's list, newest first, and a new
/// conversation. Opening one streams it; the phone keeps one open at a time.
public struct AgentConversationsView: View {
    private let backend: any ConversationBackend
    private let outbox: any OutboxStoring
    private let filesDirectory: URL
    @State private var summaries: [ConversationSummary] = []
    @State private var path: [Destination] = []
    @State private var lastSettings = ConversationSettings()

    enum Destination: Hashable {
        case existing(ConversationID)
        case new(UUID)
    }

    /// Creates the view.
    /// - Parameters:
    ///   - backend: The Mac's conversation backend.
    ///   - outbox: Where unsent messages persist.
    ///   - filesDirectory: Where picked photos and files are written.
    public init(backend: any ConversationBackend, outbox: any OutboxStoring, filesDirectory: URL) {
        self.backend = backend
        self.outbox = outbox
        self.filesDirectory = filesDirectory
    }

    public var body: some View {
        NavigationStack(path: $path) {
            List(summaries) { s in
                NavigationLink(value: Destination.existing(s.id)) {
                    VStack(alignment: .leading) {
                        Text(s.title ?? s.name).foregroundStyle(s.status == .deleted ? .red : .primary).lineLimit(1)
                        Text([s.agent, String(describing: s.status)].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(AgentStrings.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { path.append(.new(UUID())) } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel(AgentStrings.new)
                }
            }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case let .existing(id):
                    AgentChatView(model: model(for: id), filesDirectory: filesDirectory)
                case let .new(key):
                    AgentChatView(model: ConversationModel(backend: backend, conversationID: nil, settings: lastSettings, outbox: outbox, outboxKey: "new-\(key.uuidString)"), filesDirectory: filesDirectory)
                }
            }
        }
        .task {
            for await list in backend.conversationList() {
                summaries = list
                if let latest = list.first {
                    lastSettings = ConversationSettings(agent: latest.agent, workingDirectory: latest.workingDirectory)
                }
            }
        }
    }

    private func model(for id: ConversationID) -> ConversationModel {
        ConversationModel(backend: backend, conversationID: id, settings: lastSettings, outbox: outbox, outboxKey: id.rawValue)
    }
}
