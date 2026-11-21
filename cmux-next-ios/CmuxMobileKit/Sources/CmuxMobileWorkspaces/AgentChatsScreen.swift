#if os(iOS)
import CmuxAgentBrands
import CmuxMobileDesign
import CmuxMobileModel
import CmuxSpinner
import Observation
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// The Chats list's state: the Mac's chats a page at a time, which ones show (Chats or
/// Archived, and the search), and what is being done to one.
@MainActor
@Observable
public final class AgentChatsModel {
    public enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    public private(set) var chats: [AgentChatListing] = []
    public private(set) var nextCursor: String?
    public private(set) var loadingMore = false
    /// The last older page failed (the list's edge offers Try Again).
    public private(set) var moreFailure: String?
    /// The first page is being read again over the rows shown (the ones this run kept): the
    /// list shows that it is updating. A pull to refresh shows its own progress instead.
    public private(set) var refreshing = false
    public var scope: AgentChatScope = .chats
    public var query = ""
    /// The chat being opened or archived (its row shows progress; others wait).
    public private(set) var busyID: String?
    /// A refusal to show (an alert).
    public var failure: String?

    @ObservationIgnored private let macID: String
    /// Moves on each first-page load: a page asked for before it is dropped (a pull to refresh
    /// while Show Older Chats loads must never append a page after the new first page's cursor).
    @ObservationIgnored private var listGeneration = 0
    /// A first-page load is in flight: Show Older Chats waits for its cursor (the old one would
    /// append a page after the new first page and skip the ones between).
    @ObservationIgnored private var loadingFirstPage = false
    @ObservationIgnored private weak var backend: (any AgentChatsBackend)?
    /// Each Mac's chats as this run last listed them: a list opened again starts from them.
    @ObservationIgnored private let memory: AgentChatsMemory?

    /// Starts from the chats `memory` kept for the Mac (shown at once, then read again by
    /// ``load()``), else from the loading state.
    public init(macID: String, backend: (any AgentChatsBackend)?, memory: AgentChatsMemory? = .shared) {
        self.macID = macID
        self.backend = backend
        self.memory = memory
        if !macID.isEmpty, let kept = memory?.page(for: macID) {
            chats = kept.chats
            nextCursor = kept.nextCursor
            phase = .loaded
        }
    }

    /// The chats listed now are what a list opened again starts from.
    private func remember() {
        guard !macID.isEmpty, phase == .loaded else { return }
        memory?.keep(AgentChatPage(chats: chats, nextCursor: nextCursor), for: macID)
    }

    /// The rows the list shows now.
    public var visible: [AgentChatListing] { AgentChatListing.filter(chats, scope: scope, query: query) }

    /// The first page (again, for pull to refresh: `pulled`, whose own control shows progress).
    public func load(pulled: Bool = false) async {
        guard let backend else {
            phase = .failed("Not connected to the Mac.")
            return
        }
        if chats.isEmpty { phase = .loading }
        listGeneration &+= 1
        let generation = listGeneration
        loadingFirstPage = true
        refreshing = !chats.isEmpty && !pulled
        defer {
            if generation == listGeneration {
                loadingFirstPage = false
                refreshing = false
            }
        }
        do {
            let page = try await backend.agentChats(on: macID, cursor: nil)
            guard generation == listGeneration else { return }
            if let merged = chats.mergingFirstPage(page.chats, hasMore: page.nextCursor != nil) {
                // Opened again (or pulled) while older pages were read: they stay, and so does the
                // reader in them; the next cursor still reads after them.
                chats = merged
            } else {
                chats = page.chats
                nextCursor = page.nextCursor
            }
            moreFailure = nil
            phase = .loaded
            remember()
        } catch {
            guard generation == listGeneration else { return }
            let message = Self.message(error)
            if chats.isEmpty { phase = .failed(message) } else { failure = message }
        }
    }

    /// The next page, after the ones loaded.
    public func loadMore() async {
        guard let backend, let cursor = nextCursor, !loadingMore, !loadingFirstPage else { return }
        loadingMore = true
        moreFailure = nil
        defer { loadingMore = false }
        let generation = listGeneration
        do {
            let page = try await backend.agentChats(on: macID, cursor: cursor)
            guard generation == listGeneration else { return }
            let known = Set(chats.map(\.id))
            chats += page.chats.filter { !known.contains($0.id) }
            nextCursor = page.nextCursor
            remember()
        } catch {
            guard generation == listGeneration else { return }
            moreFailure = Self.message(error)
        }
    }

    /// The list's paging edge: older chats are read as the reader scrolls near the end.
    public var edge: PagedListEdge {
        if loadingMore { return .loading }
        if let moreFailure { return .failed(moreFailure) }
        return nextCursor == nil ? .end : .more
    }

    /// The chats working now (Stop All Agents' count).
    public var activeChats: [AgentChatListing] { chats.filter { $0.isActive && !$0.archived } }

    /// The last Stop All Agents' result (its toast).
    public var stopResult: AgentChatsStopResult?
    public private(set) var stoppingAll = false

    /// Stop All Agents: each working chat stops; the list reads again, so each row says so.
    public func stopAll() async {
        guard let backend, !stoppingAll else { return }
        stoppingAll = true
        defer { stoppingAll = false }
        let result = await backend.stopAll(activeChats, on: macID)
        stopResult = result
        if result.stopped.isEmpty, !result.refused.isEmpty { theme.haptics.error() } else { theme.haptics.success() }
        await load()
    }

    /// Archive or Unarchive on the Mac; the row moves to the other list when the Mac says so.
    public func setArchived(_ chat: AgentChatListing, _ archived: Bool) async {
        guard let backend, busyID == nil else { return }
        busyID = chat.id
        defer { busyID = nil }
        do {
            let now = try await backend.setAgentChatArchived(chat, archived: archived, on: macID)
            if let index = chats.firstIndex(where: { $0.id == chat.id }) { chats[index] = now }
            remember()
            theme.haptics.success()
        } catch {
            failure = Self.message(error)
            theme.haptics.error()
        }
    }

    /// Runs `work` for `chat` with its row busy; its refusal is shown.
    func run(_ chat: AgentChatListing, _ work: () async -> String?) async {
        guard busyID == nil else { return }
        busyID = chat.id
        defer { busyID = nil }
        if let refusal = await work() { failure = refusal }
    }

    static func message(_ error: any Error) -> String {
        UserFacingError.message(error)
    }
}

/// Search Agent Chats on a phone (the Mac's `agentPane.searchChats` page, "Agent Chats"):
/// every chat the Mac's acpmux knows, newest first, searched by title, folder and agent.
/// A tap opens the chat as a tab of this workspace (Open Agent Session in Tab); its menu also
/// opens it in a new workspace and archives or unarchives it. Pushed over the workspace.
struct AgentChatsScreen: View {
    let source: WorkspaceTabsSource
    @State private var model: AgentChatsModel
    @State private var confirmingStopAll = false

    private var stopAllTitle: String {
        let count = model.activeChats.count
        return count == 1 ? "Stop 1 agent on \(source.macName)?" : "Stop \(count) agents on \(source.macName)?"
    }

    init(source: WorkspaceTabsSource) {
        self.source = source
        _model = State(initialValue: AgentChatsModel(macID: source.workspace?.macID ?? "", backend: source.chatsBackend))
    }

    var body: some View {
        @Bindable var model = model
        content
            .navigationTitle(model.scope == .archived ? "Archived Chats" : "Agent Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search chats")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Show", selection: $model.scope) {
                            ForEach(AgentChatScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.inline)
                        Section {
                            // The Mac's Stop All Agents: every chat working now on this Mac.
                            Button("Stop All Agents", systemImage: "stop.circle", role: .destructive) { confirmingStopAll = true }
                                .disabled(model.activeChats.isEmpty || model.stoppingAll)
                                .accessibilityIdentifier("agentChats.stopAll")
                        }
                    } label: {
                        Label("Filter", systemImage: model.scope == .archived ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                    }
                    .accessibilityLabel("Filter")
                    .accessibilityIdentifier("agentChats.filter")
                }
            }
            .task { await model.load() }
            .confirmationDialog(stopAllTitle, isPresented: $confirmingStopAll, titleVisibility: .visible) {
                Button("Stop All Agents", role: .destructive) { Task { await model.stopAll() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Each agent stops its current turn. Its chat stays.")
            }
            .alert(model.stopResult?.summary ?? "", isPresented: Binding(get: { model.stopResult != nil }, set: { if !$0 { model.stopResult = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                if let detail = model.stopResult?.detail { Text(detail) }
            }
            .alert("Couldn't do that", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.failure ?? "")
            }
            .background(theme.colors.bg.color.ignoresSafeArea())
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            CmuxSpinner(label: Text("Loading chats…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("agentChats.loading")
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load chats", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                // The load replaces this page at once (phase .loading), which would cancel a
                // task owned by the button: the screen's model runs it unowned.
                RetryButton("Try Again") { Task { await model.load() } }
            }
            .accessibilityIdentifier("agentChats.failed")
        case .loaded:
            AgentChatsList(model: model, macName: source.macName, openHere: openHere,
                           openNew: { await source.openAgentChatInNewWorkspace($0) })
        }
    }

    /// Opens the chat as a tab here, then goes back to the workspace on it.
    private func openHere(_ chat: AgentChatListing) async -> String? {
        let refusal = await source.openAgentChat(chat)
        if refusal == nil { source.showsAgentChats = false }
        return refusal
    }
}

/// The Chats list on the shared infinite-scroll list (``PagedList``), apart from the screen so
/// its DEBUG gallery (``AgentChatsGallery``) draws the same view on fixed chats.
struct AgentChatsList: View {
    let model: AgentChatsModel
    let macName: String
    let openHere: (AgentChatListing) async -> String?
    let openNew: (AgentChatListing) async -> String?

    /// The chats on the shared infinite-scroll list (``PagedList``): older chats are read as the
    /// reader nears the end (no Show Older Chats button), and a page that lands never moves the row
    /// being read.
    var body: some View {
        let busyID = model.busyID
        let rows = model.visible.map { AgentChatsListItem(chat: $0, busy: busyID == $0.id, locked: busyID != nil) }
        return PagedList(direction: .down, items: rows, phase: .loaded, edge: model.edge,
                         loadMore: { Task { await model.loadMore() } },
                         retry: { await model.loadMore() }) { item in
            row(item)
        } empty: {
            emptyState
        }
        .pagedSwipeActions { item in
            let chat = item.chat
            return [PagedListAction(chat.archived ? "Unarchive" : "Archive", systemImage: chat.archived ? "tray.and.arrow.up" : "archivebox",
                                    tint: chat.archived ? .blue : .indigo) {
                Task { await model.setArchived(chat, !chat.archived) }
            }]
        }
        .pagedRefresh { await model.load(pulled: true) }
        .pagedIdentifier("agentChats.list")
        // The kept rows show while the Mac's newest page loads (a pull to refresh has its own).
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.refreshing {
                HStack(spacing: 8) {
                    CmuxSpinner().controlSize(.small)
                    Text("Updating…")
                        .font(.footnote)
                        .foregroundStyle(theme.colors.label2.color)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("agentChats.updating")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: model.query)
        } else if model.scope == .archived {
            ContentUnavailableView("No Archived Chats", systemImage: "archivebox",
                                   description: Text("Chats you archive show here."))
        } else {
            ContentUnavailableView("No Agent Chats", systemImage: "bubble.left.and.text.bubble.right",
                                   description: Text("Chats you start on \(macName) show here."))
        }
    }

    private func row(_ item: AgentChatsListItem) -> some View {
        let chat = item.chat
        return Button {
            Task { await model.run(chat) { await openHere(chat) } }
        } label: {
            AgentChatRow(chat: chat, busy: item.busy)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color(uiColor: .separator)).frame(height: 1 / 3).padding(.leading, 60)
                }
        }
        .buttonStyle(.cmuxPressFill)
        .disabled(item.locked)
        .contextMenu {
            Button("Open in This Workspace", systemImage: "plus.square.on.square") {
                Task { await model.run(chat) { await openHere(chat) } }
            }
            Button("Open in New Workspace", systemImage: "rectangle.stack.badge.plus") {
                Task { await model.run(chat) { await openNew(chat) } }
            }
            Divider()
            archiveButton(chat)
        }
        .accessibilityIdentifier("agentChats.row.\(chat.id)")
    }

    private func archiveButton(_ chat: AgentChatListing) -> some View {
        Button(chat.archived ? "Unarchive" : "Archive", systemImage: chat.archived ? "tray.and.arrow.up" : "archivebox") {
            Task { await model.setArchived(chat, !chat.archived) }
        }
    }
}

/// One row of the Chats list: the chat and whether a row's work (open, archive) runs now.
struct AgentChatsListItem: Identifiable, Equatable {
    let chat: AgentChatListing
    /// This row's chat is being opened or archived (its row shows progress).
    let busy: Bool
    /// Another row's work runs: rows wait.
    let locked: Bool
    var id: String { chat.id }
}

/// One chat: its agent's mark, title, folder and age, and whether it works or waits now.
struct AgentChatRow: View {
    let chat: AgentChatListing
    let busy: Bool

    private static let ages: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // At accessibility text sizes the age goes under the title and lines wrap: beside it, the
        // title truncated to a word or two.
        let large = typeSize.isAccessibilitySize
        HStack(alignment: large ? .top : .center, spacing: 12) {
            AgentBrandMark(agent: chat.harness, size: 20, style: .brand)
                .frame(width: 32, height: 32)
                .background(theme.colors.label.color.opacity(0.06), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.displayTitle)
                    .font(.body)
                    .foregroundStyle(theme.colors.label.color)
                    .lineLimit(large ? 3 : 1)
                // No blank line under the title when there is nothing to say (no status, no folder).
                if chat.isActive || !subtitle.isEmpty {
                    HStack(spacing: 6) {
                        if chat.isActive {
                            Circle().fill(chat.status == "waiting" ? Color.orange : Color.green).frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                        }
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(theme.colors.label2.color)
                            .lineLimit(large ? 2 : 1)
                            .truncationMode(.middle)
                    }
                }
                if large { trailing }
            }
            Spacer(minLength: 8)
            if !large { trailing }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint(chat.archived ? "Archived" : "")
    }

    @ViewBuilder
    private var trailing: some View {
        if busy {
            CmuxSpinner()
        } else if let updated = chat.updatedAt {
            Text(Self.ages.localizedString(for: updated, relativeTo: Date()))
                .font(.footnote)
                .foregroundStyle(theme.colors.label2.color)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if chat.status == "waiting" { parts.append("Needs you") } else if chat.status == "running" { parts.append("Working") }
        parts.append(Self.folder(chat.cwd))
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// `~/x` for a folder in a home folder, as the Mac's chats page abbreviates it.
    static func folder(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0] == "Users" {
            return (["~"] + parts.dropFirst(2).map(String.init)).joined(separator: "/")
        }
        return path
    }
}
#endif
