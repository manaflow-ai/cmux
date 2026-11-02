#if os(iOS)
import CmuxMobileModel
import SwiftUI

/// Owns one `AgentChatStore` per agent tab so the chat, Home and Feed share
/// session state (answering in the Feed updates the open chat). Live data
/// (`LiveCoordinator`) replaces `makeSource` with acpmux sources; until then a
/// tab says it is not connected. Scripted mock sessions exist only in DEBUG
/// builds with mock data on.
@MainActor
@Observable
public final class AgentSessionDirectory {
    public static let shared = AgentSessionDirectory()
    /// A cache, filled while a view body reads it: not observed, or the
    /// first read of a tab would invalidate every view that read it (each
    /// `AgentChatStore` is observable itself). `generation` tells readers
    /// when a store was replaced (`invalidate`).
    @ObservationIgnored private var stores: [String: AgentChatStore] = [:]
    private var generation = 0
    public var makeSource: (AgentSessionSummary) -> any AgentSessionSource = { summary in
        #if DEBUG
        if DeveloperOptions.mockContentEnabled {
            // Tabs made on the phone ("New session") start empty.
            return MockAgentSession(summary: summary, richFirstTurn: summary.harness == "claude", history: summary.name != "New session")
        }
        #endif
        return DisconnectedAgentSource(summary: summary)
    }

    /// A message for the next new agent chat that opens with its composer up (New Agent Chat
    /// from Shortcuts with a prompt): it goes into that composer, unsent, once.
    @ObservationIgnored public var newChatDraft: String?

    public init() {}

    /// A tab's store key: tab ids (`s<surface>`) repeat across Macs, so a
    /// tab of a known Mac is keyed with it.
    public static func key(id: String, macID: String) -> String {
        macID.isEmpty ? id : "\(macID)\u{1}\(id)"
    }

    public func store(for summary: AgentSessionSummary) -> AgentChatStore {
        _ = generation
        let key = Self.key(id: summary.id, macID: summary.macID)
        if let store = stores[key] { return store }
        let store = AgentChatStore(source: makeSource(summary))
        stores[key] = store
        return store
    }

    /// Every chat loaded in this launch (notification previews save their last messages).
    public var loadedStores: [AgentChatStore] { Array(stores.values) }

    public func existingStore(id: String, macID: String = "") -> AgentChatStore? {
        _ = generation
        return stores[Self.key(id: id, macID: macID)]
    }

    /// Forgets the tab's store; the next `store(for:)` builds one from
    /// `makeSource` again (the tab's session changed on the Mac).
    public func invalidate(id: String, macID: String = "") {
        guard stores.removeValue(forKey: Self.key(id: id, macID: macID)) != nil else { return }
        generation += 1
    }

    /// Sign-out: no account's chats stay in memory (notification previews save `loadedStores`, and a
    /// later sign-in must not meet a store bound to the old account's link).
    public func removeAll() {
        guard !stores.isEmpty else { return }
        stores.removeAll()
        generation += 1
    }

    public func store(workspace: Workspace, tab: WorkspaceTab, macName: String) -> AgentChatStore {
        store(for: AgentSessionSummary(
            id: tab.id, name: tab.subtitle ?? tab.title, harness: tab.harness ?? "claude", agentName: tab.title,
            cwd: workspace.directory, workspaceTitle: workspace.title, macName: macName, branch: workspace.branch,
            status: tab.agentStatus.map { $0 == .waiting ? .waiting : .running } ?? .idle,
            macID: workspace.macID
        ))
    }
}

/// A navigation value that opens an agent tab's chat.
public struct AgentChatDestination: Hashable, Sendable {
    public var workspaceID: String
    public var tabID: String

    public init(workspaceID: String, tabID: String) {
        self.workspaceID = workspaceID
        self.tabID = tabID
    }
}

/// Resolves a destination against the app store and shows the chat.
public struct AgentChatDestinationView: View {
    let destination: AgentChatDestination
    @Environment(AppStore.self) private var appStore

    public init(destination: AgentChatDestination) {
        self.destination = destination
    }

    public var body: some View {
        if let workspace = appStore.workspaces.first(where: { $0.id == destination.workspaceID }),
           let tab = workspace.tabs.first(where: { $0.id == destination.tabID }) {
            let mac = appStore.teams.flatMap(\.macs).first { $0.id == workspace.macID }?.name ?? "Mac"
            AgentChatScreen(store: AgentSessionDirectory.shared.store(workspace: workspace, tab: tab, macName: mac))
                .onAppear { appStore.noteOpened(tabID: tab.id, in: workspace.id) }
        } else {
            ContentUnavailableView("Tab closed", systemImage: "sparkle", description: Text("This agent tab is no longer open."))
        }
    }
}

extension View {
    /// Registers `AgentChatDestination` on the enclosing NavigationStack.
    public func agentChatDestinations() -> some View {
        navigationDestination(for: AgentChatDestination.self) { AgentChatDestinationView(destination: $0) }
    }
}
#endif
