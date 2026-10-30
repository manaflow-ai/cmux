#if os(iOS)
import CmuxAgentBrands
import CmuxMobileDesign
import CmuxMobileModel
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

    public init(macID: String, backend: (any AgentChatsBackend)?) {
        self.macID = macID
        self.backend = backend
    }

    /// The rows the list shows now.
    public var visible: [AgentChatListing] { AgentChatListing.filter(chats, scope: scope, query: query) }

    /// The first page (again, for pull to refresh).
    public func load() async {
        guard let backend else {
            phase = .failed("Not connected to the Mac.")
            return
        }
        if chats.isEmpty { phase = .loading }
        listGeneration &+= 1
        let generation = listGeneration
        loadingFirstPage = true
        defer { if generation == listGeneration { loadingFirstPage = false } }
        do {
            let page = try await backend.agentChats(on: macID, cursor: nil)
            guard generation == listGeneration else { return }
            chats = page.chats
            nextCursor = page.nextCursor
            phase = .loaded
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
        defer { loadingMore = false }
        let generation = listGeneration
        do {
            let page = try await backend.agentChats(on: macID, cursor: cursor)
            guard generation == listGeneration else { return }
            let known = Set(chats.map(\.id))
            chats += page.chats.filter { !known.contains($0.id) }
            nextCursor = page.nextCursor
        } catch {
            guard generation == listGeneration else { return }
            failure = Self.message(error)
        }
    }

    /// Archive or Unarchive on the Mac; the row moves to the other list when the Mac says so.
    public func setArchived(_ chat: AgentChatListing, _ archived: Bool) async {
        guard let backend, busyID == nil else { return }
        busyID = chat.id
        defer { busyID = nil }
        do {
            let now = try await backend.setAgentChatArchived(chat, archived: archived, on: macID)
            if let index = chats.firstIndex(where: { $0.id == chat.id }) { chats[index] = now }
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
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

/// Search Agent Chats on a phone (the Mac's `agentPane.searchChats` page, "Agent Chats"):
/// every chat the Mac's acpmux knows, newest first, searched by title, folder and agent.
/// A tap opens the chat as a tab of this workspace (Open Agent Session in Tab); its menu also
/// opens it in a new workspace and archives or unarchives it. Pushed over the workspace.
struct AgentChatsScreen: View {
    let source: WorkspaceTabsSource
    @State private var model: AgentChatsModel

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
                    } label: {
                        Label("Filter", systemImage: model.scope == .archived ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                    }
                    .accessibilityLabel("Filter")
                    .accessibilityIdentifier("agentChats.filter")
                }
            }
            .refreshable { await model.load() }
            .task { await model.load() }
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
            ProgressView("Loading chats…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("agentChats.loading")
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load chats", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.load() } }
                    .buttonStyle(.borderedProminent)
            }
            .accessibilityIdentifier("agentChats.failed")
        case .loaded:
            list
        }
    }

    private var list: some View {
        let rows = model.visible
        return List {
            ForEach(rows) { chat in
                row(chat)
            }
            if model.nextCursor != nil {
                Section {
                    Button {
                        Task { await model.loadMore() }
                    } label: {
                        HStack {
                            Text("Show Older Chats")
                            Spacer()
                            if model.loadingMore { ProgressView() }
                        }
                    }
                    .disabled(model.loadingMore)
                    .accessibilityIdentifier("agentChats.more")
                } footer: {
                    if !model.query.isEmpty { Text("Search covers the chats shown so far.") }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if rows.isEmpty, model.nextCursor == nil {
                emptyState
            }
        }
        .accessibilityIdentifier("agentChats.list")
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
                                   description: Text("Chats you start on \(source.macName) show here."))
        }
    }

    private func row(_ chat: AgentChatListing) -> some View {
        Button {
            Task { await model.run(chat) { await openHere(chat) } }
        } label: {
            AgentChatRow(chat: chat, busy: model.busyID == chat.id)
        }
        .disabled(model.busyID != nil)
        .contextMenu {
            Button("Open in This Workspace", systemImage: "plus.square.on.square") {
                Task { await model.run(chat) { await openHere(chat) } }
            }
            Button("Open in New Workspace", systemImage: "rectangle.stack.badge.plus") {
                Task { await model.run(chat) { await source.openAgentChatInNewWorkspace(chat) } }
            }
            Divider()
            archiveButton(chat)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            archiveButton(chat).tint(chat.archived ? .blue : .indigo)
        }
        .accessibilityIdentifier("agentChats.row.\(chat.id)")
    }

    private func archiveButton(_ chat: AgentChatListing) -> some View {
        Button(chat.archived ? "Unarchive" : "Archive", systemImage: chat.archived ? "tray.and.arrow.up" : "archivebox") {
            Task { await model.setArchived(chat, !chat.archived) }
        }
    }

    /// Opens the chat as a tab here, then goes back to the workspace on it.
    private func openHere(_ chat: AgentChatListing) async -> String? {
        let refusal = await source.openAgentChat(chat)
        if refusal == nil { source.showsAgentChats = false }
        return refusal
    }
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

    var body: some View {
        HStack(spacing: 12) {
            AgentBrandMark(agent: chat.harness, size: 20, style: .brand)
                .frame(width: 32, height: 32)
                .background(theme.colors.label.color.opacity(0.06), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.displayTitle)
                    .font(.body)
                    .foregroundStyle(theme.colors.label.color)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if chat.isActive {
                        Circle().fill(chat.status == "waiting" ? Color.orange : Color.green).frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(theme.colors.label2.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if busy {
                ProgressView()
            } else if let updated = chat.updatedAt {
                Text(Self.ages.localizedString(for: updated, relativeTo: Date()))
                    .font(.footnote)
                    .foregroundStyle(theme.colors.label2.color)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint(chat.archived ? "Archived" : "")
    }

    private var subtitle: String {
        var parts: [String] = []
        if chat.status == "waiting" { parts.append("Needs you") } else if chat.status == "running" { parts.append("Working") }
        parts.append(Self.folder(chat.cwd))
        return parts.joined(separator: " · ")
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
