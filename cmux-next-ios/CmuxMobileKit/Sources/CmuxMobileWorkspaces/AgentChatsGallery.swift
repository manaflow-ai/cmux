#if DEBUG && os(iOS)
import CmuxMobileModel
import SwiftUI

/// The Chats list (``AgentChatsList``, on the shared ``PagedList``) on fixed chats, for screenshots
/// and UI tests of every state (verify/paged-list.md). Scenarios: `pages` (three pages of 20 chats,
/// 0.6 s each, then the end), `edgefail` (the second page fails once; Try Again reads it), `slow`
/// (6 s older pages: the edge's spinner), `empty`, `firstfail` (no chats: the screen's failure),
/// `dupes` (the first page sends one chat twice), `emptythenone` (empty until a pull to refresh reads one chat).
public struct AgentChatsGallery: View {
    @State private var model: AgentChatsModel
    /// Held here: the model keeps its backend weakly, as the app's workspace source owns the real one.
    @State private var backend: GalleryChatsBackend

    public init(scenario: String) {
        let backend = GalleryChatsBackend(scenario: scenario)
        _backend = State(initialValue: backend)
        _model = State(initialValue: AgentChatsModel(macID: "gallery", backend: backend, memory: nil))
    }

    public var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .loaded:
                    AgentChatsList(model: model, macName: "Studio Mac", openHere: { _ in nil }, openNew: { _ in nil })
                case .loading:
                    ProgressView()
                case .failed(let message):
                    ContentUnavailableView("Couldn't load chats", systemImage: "exclamationmark.triangle", description: Text(message))
                        .accessibilityIdentifier("agentChats.failed")
                }
            }
            .navigationTitle("Agent Chats")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await model.load() }
    }
}

@MainActor
final class GalleryChatsBackend: AgentChatsBackend {
    let scenario: String
    private var failed = false
    private var firstReads = 0

    init(scenario: String) { self.scenario = scenario }

    struct Refused: LocalizedError {
        var errorDescription: String? { "The gallery's Mac did not answer." }
    }

    func canListAgentChats(on macID: String) -> Bool { true }

    func agentChats(on macID: String, cursor: String?) async throws -> AgentChatPage {
        // motion: not an animation; the gallery's Mac answers after a network-like delay.
        try await Task.sleep(for: scenario == "slow" && cursor != nil ? .seconds(6) : .milliseconds(600))
        if scenario == "firstfail" { throw Refused() }
        if scenario == "empty" { return AgentChatPage(chats: [], nextCursor: nil) }
        if scenario == "emptythenone", cursor == nil {
            firstReads += 1
            if firstReads == 1 { return AgentChatPage(chats: [], nextCursor: nil) }
        }
        let start = cursor.flatMap(Int.init) ?? 0
        if scenario == "edgefail", start == 20, !failed {
            failed = true
            throw Refused()
        }
        let harnesses = ["claude", "codex", "claude", "gemini"]
        let titles = ["Fix the paged list's anchor", "Ship iOS infinite scroll", "Review #45778", "Agent chats search",
                      "Workspace sidebar groups", "Dark mode pass", "Composer keyboard pin", "Feed pagination plan"]
        let statuses = ["idle", "running", "waiting", "idle", "idle"]
        let count = scenario == "emptythenone" ? 1 : 20
        var chats = (start..<(start + count)).map { n in
            AgentChatListing(id: "chat-\(n)", title: "\(titles[n % titles.count]) \(n)", harness: harnesses[n % harnesses.count],
                             cwd: "/Users/aziz/Development/cmux/worktrees/task-\(n % 7)", status: statuses[n % statuses.count],
                             updatedAt: Date(timeIntervalSinceReferenceDate: 815_000_000 - Double(n) * 3_600), archived: false)
        }
        if scenario == "dupes", start == 0 { chats.insert(chats[3], at: 7) }
        let end = start + count
        return AgentChatPage(chats: chats, nextCursor: end < 60 && count == 20 ? String(end) : nil)
    }

    func openAgentChat(_ chat: AgentChatListing, in workspace: Workspace) async throws -> WorkspaceTab { throw Refused() }
    func openAgentChatInNewWorkspace(_ chat: AgentChatListing, on macID: String) async throws -> Workspace { throw Refused() }
    func setAgentChatArchived(_ chat: AgentChatListing, archived: Bool, on macID: String) async throws -> AgentChatListing {
        var changed = chat
        changed.archived = archived
        return changed
    }
    func openChatFolderInTerminal(_ tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab { throw Refused() }
    func stopAgentChat(_ chat: AgentChatListing, on macID: String) async throws {}
    func launchAgentTeams(_ teams: AgentTeamsLaunch, beside tab: WorkspaceTab?, folder: String?,
                          in workspace: Workspace) async throws -> WorkspaceTab { throw Refused() }
}
#endif
