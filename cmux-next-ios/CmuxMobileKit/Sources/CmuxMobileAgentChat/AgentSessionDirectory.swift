#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import CmuxSpinner
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

    /// New Agent Chat from Shortcuts with a prompt: the message waits for the chat of the
    /// workspace it made (`workspaceID`, the placeholder's id until the Mac names it) and goes
    /// into that chat's composer, unsent, once. One left over (the person went elsewhere) is
    /// dropped after `expiresAt`.
    public struct NewChatDraft: Sendable {
        public var workspaceID: String
        public var text: String
        public var expiresAt: Date

        public init(workspaceID: String, text: String, expiresAt: Date) {
            self.workspaceID = workspaceID
            self.text = text
            self.expiresAt = expiresAt
        }
    }

    @ObservationIgnored public var newChatDraft: NewChatDraft?

    /// The draft for the chat of workspace `id` (`resolve` maps a placeholder's id to the Mac's),
    /// taken once; nil when there is none for it, or it is too old.
    public func takeNewChatDraft(for id: String, now: Date = Date(), resolve: (String) -> String) -> String? {
        guard let draft = newChatDraft else { return nil }
        if draft.expiresAt < now {
            newChatDraft = nil
            return nil
        }
        guard resolve(draft.workspaceID) == resolve(id) else { return nil }
        newChatDraft = nil
        return draft.text
    }

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
        // Kept for the tab while the person is elsewhere: it spills and answers memory warnings
        // on its own, as the chat on screen does.
        store.boundsMemoryOffScreen()
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

    /// The tab and workspace last found, kept while the tab is missing from a reconnect's partial resync.
    private final class Remembered {
        var found: (workspace: Workspace, tab: WorkspaceTab)?
        /// What to show: the tab found now (kept), else the one last found unless it closed.
        func shown(_ now: (workspace: Workspace, tab: WorkspaceTab)?, closed: Bool) -> (workspace: Workspace, tab: WorkspaceTab)? {
            if let now { found = now; return now }
            return closed ? nil : found
        }
    }
    @State private var remembered = Remembered()
    /// The tab stayed missing on a connected Mac past the grace: it closed.
    @State private var confirmedClosed = false
    /// The loading state's words wait out ``QuietStatusGate/threshold``: a cold open usually
    /// lands first, with only the spinner shown (iOS release bar read-back, 2026-11-22, shot 14).
    @State private var loadingWords = QuietStatusGate()

    private var current: (workspace: Workspace, tab: WorkspaceTab)? {
        guard let workspace = appStore.workspaces.first(where: { $0.id == destination.workspaceID }),
              let tab = workspace.tabs.first(where: { $0.id == destination.tabID }) else { return nil }
        return (workspace, tab)
    }

    public var body: some View {
        let found = current
        if let shown = remembered.shown(found, closed: confirmedClosed) {
            let mac = appStore.teams.flatMap(\.macs).first { $0.id == shown.workspace.macID }?.name ?? "Mac"
            AgentChatScreen(store: AgentSessionDirectory.shared.store(workspace: shown.workspace, tab: shown.tab, macName: mac))
                .onAppear { appStore.noteOpened(tabID: shown.tab.id, in: shown.workspace.id) }
                .task(id: found == nil ? (linkUp(shown.workspace.macID) ? 2 : 1) : 0) {
                    // A reconnect can list the workspace without the tab for a few seconds: the chat
                    // stays, and "Tab closed" shows only once the tab stays missing on a connected Mac.
                    guard found == nil, linkUp(shown.workspace.macID) else { return }
                    try? await Task.sleep(for: .seconds(10))
                    if !Task.isCancelled, current == nil, linkUp(shown.workspace.macID) { confirmedClosed = true }
                }
        } else if isLoading {
            // The workspaces are still on their way (a cold open from a notification): the
            // chat loads, it is not "closed".
            VStack(spacing: 12) {
                CmuxSpinner()
                // Keeps its room while hidden, so the spinner never moves when it shows.
                Text("Loading chat…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .opacity(loadingWords.isShown ? 1 : 0)
                    .animation(.cmuxMobileSmooth.unlessReduceMotion, value: loadingWords.isShown)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Loading chat…"))
            .accessibilityIdentifier("agentChat.destination.loading")
            .placeholderBound("chat.destination.loading", .milliseconds(2000))
            .onAppear { loadingWords.update(down: true) }
            .onDisappear { loadingWords.update(down: false) }
        } else {
            ContentUnavailableView("Tab closed", systemImage: "sparkle", description: Text("This agent tab is no longer open."))
        }
    }

    private func linkUp(_ macID: String) -> Bool {
        appStore.macConnection[macID].map { $0 == .connected } ?? true
    }

    /// The tab may still come: the team's data or a Mac's list is loading (or showing last-known
    /// rows while its link comes up). Only a live list that lacks the tab means it closed.
    private var isLoading: Bool {
        if appStore.teamDataState == .loading { return true }
        let workspace = appStore.workspaces.first { $0.id == destination.workspaceID }
        let macs = workspace.map { [$0.macID] } ?? Array(appStore.macData.keys)
        if workspace == nil, appStore.tracksMacData, appStore.macData.isEmpty { return true }
        return macs.contains { macID in
            switch appStore.macDataPhase(macID) {
            case .loading, .cached: true
            case .live, .empty, .failed, .offline, .idle: false
            }
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
