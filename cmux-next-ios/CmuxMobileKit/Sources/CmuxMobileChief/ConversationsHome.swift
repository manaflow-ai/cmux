#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import SwiftUI
import UIKit

private let theme = CmuxMobileTheme.standard

/// Home (user direction 2026-10-21: "Home should be exact information parity
/// with macOS"): the Mac's Home list, the rows its conversation owner derives
/// (`home-inbox`, ``MacHomeFeed``) drawn as the Mac's Home sidebar draws them
/// (`HomeSidebarModel`): the pinned grid in the owner's pin order, then every
/// other conversation newest first, each with its avatar, name, where a Chief
/// runs, preview, time, unread dot and typing. The Cloud Chief (the account's
/// Chief, which the Mac lists as its Main Chief tagged "Main · Cloud") is a row
/// placed by its newest message; its pin is the Cloud inbox's, which the phone
/// does not read, so it never takes a tile.
/// The header has what the Mac's has: search, the Unread toggle (the Mac's only
/// filter) and compose. Agent chats live in their workspaces, as on the Mac.
/// The list shows one Mac's Home, the focused Mac's; the Mac menu picks it.
public struct ConversationsHome<Leading: ToolbarContent>: View {
    let store: AppStore
    /// The Cloud Chief (the default once it answers) and the Mac Chief.
    let sources: ChiefSources
    let feed: MacHomeFeed
    let leading: Leading
    let open: (HomeConversationRoute) -> Void
    /// The Mac filter, shared with Workspaces (remembered per team): here it picks whose Home shows.
    let macFilter: MacFilter
    /// Live: choosing a Mac links it and moves the Mac Chief and Home to it.
    let selectMac: ((String) -> Void)?
    let reconnect: ((String) async -> Void)?
    @State private var macText = MacFilterMemo()
    /// The filtered list, built once per change of the rows, search or toggle.
    @State private var listMemo = MacHomeList.Memo()
    @State private var query = ""
    @State private var unreadOnly = false
    /// The New Chief name prompt is up.
    @State private var namingChief = false
    @State private var newChiefName = ""

    /// `open` pushes a conversation New Message opened onto Home's stack.
    public init(store: AppStore, sources: ChiefSources = .shared, feed: MacHomeFeed = .shared, macFilter: MacFilter = MacFilter(),
                reconnect: ((String) async -> Void)? = nil,
                selectMac: ((String) -> Void)? = nil,
                open: @escaping (HomeConversationRoute) -> Void,
                @ToolbarContentBuilder leading: () -> Leading) {
        self.store = store
        self.sources = sources
        self.feed = feed
        self.macFilter = macFilter
        self.selectMac = selectMac
        self.reconnect = reconnect
        self.open = open
        self.leading = leading()
    }

    /// The listed Macs (one per computer, whatever builds run on it: ``MacRoster``).
    private var macs: [MacDevice] { macText.roster(store.activeTeam?.macs ?? []).visible }

    private var labels: HomeMacLabels {
        HomeMacLabels(macs: macs, scope: macFilter.scope(in: store.activeTeam),
                             accountMacs: MacRoster.accountMacs(store.teams))
    }

    /// The default Chief: compose, New Message and the first pin.
    private var session: ChiefSession { sources.primary }

    /// The Mac whose Home shows: the one its rows came from, else the Mac Chief's.
    private var homeMacID: String? { feed.macID ?? sources.mac.macID }

    private var homeIsOffline: Bool {
        guard store.tracksMacData, let homeMacID else { return false }
        return store.macConnection[homeMacID] != .connected && store.macConnection[homeMacID] != .connecting
    }

    /// Under a Chief's name: where it runs ("Cloud", or the Mac's name), as the Mac's list tags each Chief.
    private var macTag: String? {
        labels.chiefDetail(place: .mac, macID: homeMacID, macName: sources.mac.macName)
    }

    /// The Mac's list as its sidebar lays it out, under the search and the Unread toggle.
    private var list: MacHomeList { listMemo.list(feed.rows ?? [], query: query, unreadOnly: unreadOnly) }

    /// The Cloud Chief (the Mac lists it as its Main Chief, "Main · Cloud", among the rows by its
    /// newest message), while it answers and passes the filters.
    private var showsCloudChief: Bool {
        guard sources.isCloudReady else { return false }
        if unreadOnly, sources.cloud.unreadCount == 0 { return false }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty || primaryName.localizedStandardContains(needle) || sources.cloud.preview.localizedStandardContains(needle)
    }

    /// Before the Mac's list arrives (no Mac yet, or it is connecting), its Chief stays reachable.
    private var fallbackMacChief: ChiefSession? {
        guard feed.rows == nil, query.isEmpty else { return nil }
        let mac = sources.mac
        let holds = !mac.outbox.isEmpty || mac.unreadCount > 0 || mac.openQuestion != nil
        guard mac.macName != nil || holds || !sources.isCloudReady else { return nil }
        if unreadOnly, mac.unreadCount == 0 { return nil }
        return mac
    }

    /// The Mac Chief's own conversation: the one its session holds, else the one the Mac's
    /// list names (before the session has found it).
    private func isMacChief(_ row: MacHomeRow) -> Bool {
        row.id == sources.mac.conversationID || (sources.mac.conversationID == nil && row.id == feed.macChiefID)
    }

    /// Where a row of the Mac's list goes: the Mac Chief's own conversation is the Mac Chief.
    private func route(_ row: MacHomeRow) -> HomeConversationRoute {
        if isMacChief(row) { return .chief(.mac) }
        return .mac(MacConversationRoute(conversationID: row.id, chief: row.chief, title: row.title))
    }

    /// A row's avatar text: the Mac Chief's own avatar for its conversation, else the name's initials.
    private func avatarText(_ row: MacHomeRow) -> String {
        if isMacChief(row) { return sources.mac.avatar }
        return homeInitials(row.title)
    }

    /// The tag after a row's name, as the Mac's list draws it (`HomeChiefRoster.tag`): "Main" for
    /// the main Chief (the Cloud Chief when there is one, else this Mac's), then where a Chief runs.
    private func tag(_ row: MacHomeRow) -> String? {
        guard row.kind == .chief else { return nil }
        return chiefTag(main: !sources.isCloudReady && isMacChief(row), place: macTag)
    }

    private func chiefTag(main: Bool, place: String?) -> String? {
        let parts = [main ? String(localized: "Main") : nil, place].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// One row of Home: a row of the Mac's list, the Cloud Chief, or the Mac Chief before the list arrives.
    enum Entry: Identifiable {
        case row(MacHomeRow)
        case cloud
        case macChief
        var id: String {
            switch self {
            case let .row(row): row.id
            case .cloud: "cloud-chief"
            case .macChief: "mac-chief"
            }
        }
    }

    /// The rows in the Mac's order, with the Cloud Chief (and, before the list arrives, the Mac
    /// Chief) placed among the unpinned rows by its newest message, as the Mac merges its owners.
    private func entries(_ list: MacHomeList) -> [Entry] {
        var entries = list.rows.map(Entry.row)
        func place(_ entry: Entry, at date: Date) {
            let index = entries.firstIndex { if case let .row(row) = $0 { return !row.isPinned && row.activityAt < date }; return false }
            entries.insert(entry, at: index ?? entries.endIndex)
        }
        if let mac = fallbackMacChief { place(.macChief, at: mac.lastMessage?.sentAt ?? .distantPast) }
        if showsCloudChief { place(.cloud, at: sources.cloud.lastMessage?.sentAt ?? .distantPast) }
        return entries
    }


    public var body: some View {
        let stamp = MessagesStamp()
        let list = list
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        List {
            let tiles = pinnedTiles(list)
            if !tiles.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0, alignment: .bottom), count: 3), spacing: 4) {
                    ForEach(tiles) { $0 }
                }
                .padding(.horizontal, 8)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(theme.colors.bg.color)
            }
            // The Cloud Chief could not take the pin: say why.
            if !unreadOnly, !searching, let status = sources.cloudStatus {
                VStack(spacing: 6) {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(theme.colors.label2.color)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("home.chief.cloudStatus")
                    cloudActions
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(theme.colors.bg.color)
            } else if !unreadOnly, !searching, let error = sources.changeError {
                // A refused switch or create while the Cloud Chief is open.
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Color(uiColor: .systemRed))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 8)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(theme.colors.bg.color)
                    .accessibilityIdentifier("home.chief.changeError")
            }
            let entries = entries(list)
            ForEach(entries) { entry in
                switch entry {
                case let .row(row):
                    // Plain values: SwiftUI skips the rows that did not change.
                    // The list-row traits outside the Equatable view, where List sees them.
                    HomeListRow(model: rowModel(row, stamp: stamp), open: open, feed: feed)
                        .equatable()
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 16))
                        .listRowBackground(theme.colors.bg.color)
                case .cloud:
                    sessionRow(sources.cloud, name: primaryName, tag: chiefTag(main: true, place: String(localized: "Cloud")),
                               stamp: stamp, identifier: "home.chief", place: .cloud) { cloudTileMenu }
                case .macChief:
                    sessionRow(sources.mac, name: String(localized: "Chief"), tag: chiefTag(main: !sources.isCloudReady, place: macTag),
                               stamp: stamp, identifier: "home.chief.mac", place: .mac) { callChiefItem }
                }
            }
            if !searching, feed.problem != nil || homeIsOffline {
                VStack(spacing: 6) {
                    Text(RecoveryMessage.home.text)
                        .font(.footnote)
                        .foregroundStyle(theme.colors.label2.color)
                    RetryButton {
                        await HomeRetryAction(feed: feed, reconnect: reconnect).retry(macID: homeMacID, reconnectNeeded: homeIsOffline)
                    }
                    .accessibilityIdentifier("home.retry")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(theme.colors.bg.color)
                .accessibilityIdentifier("home.note.problem")
            } else if feed.rows == nil, homeMacID != nil, !searching {
                note(String(localized: "Connecting to \(macTag ?? String(localized: "your Mac"))…"), identifier: "home.note.connecting")
            }
            if tiles.isEmpty, entries.isEmpty, feed.rows != nil || searching || unreadOnly {
                Text(unreadOnly ? "No Unread Conversations" : searching ? "No Results" : "No Conversations")
                    .font(.callout)
                    .foregroundStyle(theme.colors.label2.color)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 120)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(theme.colors.bg.color)
                    .accessibilityIdentifier("home.empty")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.colors.bg.color.ignoresSafeArea())
        // The Mac's search field, as the native drawer revealed by a pull-down.
        .cmuxMobilePullDownSearch(text: $query)
        // No visible title (user feedback): the grid sits right under the
        // toolbar. The title still names the screen for VoiceOver and the back menu.
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbar {
            leading
            ToolbarItemGroup(placement: .topBarTrailing) {
                if macs.count > 1 { macMenu }
                // The Mac's Unread toggle: all or unread only, the filled glyph while on.
                Button {
                    theme.haptics.selection()
                    withAnimation(theme.motion.smooth.animation) { unreadOnly.toggle() }
                } label: {
                    Label("Unread", systemImage: unreadOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityIdentifier("home.unread")
                .accessibilityValue(unreadOnly ? "On" : "Off")
                // Compose opens the Chief conversation with the keyboard up
                // (SPEC 1.4): the phone starts no conversations.
                Button("New Message to Chief", systemImage: "square.and.pencil") {
                    open(.chiefComposing(sources.primaryPlace))
                }
                .accessibilityIdentifier("home.compose")
            }
        }
        .navigationDestination(for: ChiefRoute.self) { route in
            let chief = sources.session(for: route.place)
            ChiefConversationScreen(session: chief, compose: ChiefComposer(store: store, session: chief, open: open),
                                    focusesComposer: route.focusesComposer)
        }
        .navigationDestination(for: MacConversationRoute.self) { route in
            MacConversationScreen(route: route, feed: feed, macID: homeMacID, reconnect: reconnect)
        }
        // Back on Home: read the Cloud Chiefs again (one may be archived or deleted elsewhere), and the Mac's list.
        .task {
            sources.recheck()
            feed.refresh()
        }
        .alert("New Chief", isPresented: $namingChief) {
            TextField("Name", text: $newChiefName)
                // Names and prompts are code-like: no autocorrect, no capitals (full verify D5).
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("home.chief.newName")
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newChiefName
                Task { await sources.createChief(named: name) }
            }
            .accessibilityIdentifier("home.chief.newCreate")
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("A new Cloud Chief with its own conversation and memory.")
        }
        // The memo's revision moves only when the shown list does (no comparison of every row per pass).
        .animation(theme.motion.smooth.animation, value: listMemo.revision)
    }

    private func rowModel(_ row: MacHomeRow, stamp: MessagesStamp) -> HomeListRow.Model {
        HomeListRow.Model(id: row.id, title: row.title, subtitle: tag(row), preview: row.preview,
                          stamp: row.activityAt > .distantPast ? stamp.string(for: row.activityAt) : "",
                          isUnread: row.unreadCount > 0, isMuted: row.isMuted, isTyping: row.isWorking,
                          isPinned: row.isPinned, avatar: avatarText(row), isMacChief: isMacChief(row), route: route(row))
    }

    /// The grid's tiles: the Mac's pinned conversations in the owner's order.
    /// Each tile is its own button, so a tap opens that tile only.
    private func pinnedTiles(_ list: MacHomeList) -> [HomeTile] {
        var tiles: [HomeTile] = []
        for row in list.pinned {
            let macChief = isMacChief(row)
            tiles.append(HomeTile(id: row.id, avatar: avatarText(row), name: row.title, detail: tag(row),
                                  unread: row.unreadCount > 0, working: row.isWorking,
                                  bubble: row.unreadCount > 0 && !row.preview.isEmpty ? row.preview : nil,
                                  muted: row.isMuted, identifier: macChief ? "home.chief.mac" : "home.pin.\(row.id)",
                                  open: { open(route(row)) }, menu: AnyView(rowMenu(row))))
        }
        return tiles
    }

    /// A Chief the phone holds itself (the Cloud Chief, or the Mac Chief before the list arrives) as a row.
    private func sessionRow<Menu: View>(_ chief: ChiefSession, name: String, tag: String?, stamp: MessagesStamp, identifier: String,
                                        place: ChiefRoute.Place, @ViewBuilder menu: () -> Menu) -> some View {
        Button { open(.chief(place)) } label: {
            MessagesRow(title: name, subtitle: tag, preview: plainPreview(chief.preview),
                        stamp: chief.lastMessage.map { stamp.string(for: $0.sentAt) } ?? "",
                        isUnread: chief.unreadCount > 0, isMuted: chief.isMuted, needsYou: chief.needsYou,
                        isTyping: chief.isWorking) { size in
                ChiefAvatar(text: chief.avatar, size: size)
            }
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 16))
        .listRowBackground(theme.colors.bg.color)
        .contextMenu { menu() }
        .accessibilityIdentifier(identifier)
    }

    /// The Mac's row menu, the actions that are the person's list state:
    /// Pin or Unpin, Mark as Read or Mark as Unread; Chief's row also calls Chief.
    private func rowMenu(_ row: MacHomeRow) -> some View {
        HomeRowMenu(id: row.id, isMacChief: isMacChief(row), isPinned: row.isPinned, isUnread: row.unreadCount > 0, feed: feed)
    }

    private var callChiefItem: some View { CallChiefItem() }

    @ViewBuilder private var cloudTileMenu: some View {
        let cloud = sources.cloud
        callChiefItem
        if cloud.conversationID != nil {
            Button(cloud.isMuted ? "Show Alerts" : "Hide Alerts", systemImage: cloud.isMuted ? "bell" : "bell.slash") {
                cloud.setMuted(!cloud.isMuted)
            }
        }
        ChiefPickerItems(sources: sources, newChief: newChiefAction)
    }

    private func note(_ text: String, identifier: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(theme.colors.label2.color)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(theme.colors.bg.color)
            .accessibilityIdentifier(identifier)
    }

    /// Whose Home shows: each Mac (online first) with its presence and link
    /// line; choosing one links it, as on Workspaces.
    private var macMenu: some View {
        let entries = macText.entries(MacFilterMemo.Input(macs: macs, connection: store.macConnection,
                                                          linkStatus: store.macLinkStatus, live: store.tracksMacData,
                                                          now: MinuteClock.shared.now))
        return Menu {
            Section("Show Home of") {
                ForEach(entries) { mac in
                    Toggle(isOn: chosen(mac.id)) {
                        Text(mac.title)
                        Text(mac.detail)
                        Image(systemName: "desktopcomputer")
                    }
                    .accessibilityIdentifier("home.mac.\(mac.id)")
                }
            }
        } label: {
            Label("Mac", systemImage: "desktopcomputer")
        }
        .accessibilityIdentifier("home.mac")
        .accessibilityValue(homeMacID.flatMap { labels.macName($0) } ?? "")
    }

    private func chosen(_ id: String) -> Binding<Bool> {
        Binding(get: { homeMacID == id }, set: { if $0 { selectHome(id) } })
    }

    private func selectHome(_ id: String) {
        guard let team = store.activeTeam, id != homeMacID else { return }
        theme.haptics.selection()
        withAnimation(theme.motion.smooth.animation) { macFilter.select(.mac(id), in: team.id) }
        // The chosen Mac is linked and focused: its Chief and its Home show.
        if macs.contains(where: { $0.id == id && $0.isOnline }) { selectMac?(id) }
    }

    /// The first pin's name: the Cloud Chief's own name once it is the default.
    private var primaryName: String {
        if let chief = sources.cloudChief, !chief.displayName.isEmpty { return chief.displayName }
        return String(localized: "Chief")
    }

    /// New Chief only where this service answered a Chief brain route.
    private var newChiefAction: (() -> Void)? {
        guard sources.brainsAvailable else { return nil }
        return { startNewChief() }
    }

    private func startNewChief() {
        newChiefName = String(localized: "Chief")
        namingChief = true
    }

    /// Under the Cloud status: make a chief, turn its brain on, or open another one.
    @ViewBuilder private var cloudActions: some View {
        HStack(spacing: 12) {
            switch sources.cloudAction {
            case .create:
                Button("Create Cloud Chief", action: startNewChief)
                    .accessibilityIdentifier("home.chief.create")
            case let .turnOn(chief):
                Button("Turn On Cloud Chief") { Task { await sources.turnOn(chief) } }
                    .accessibilityIdentifier("home.chief.turnOn")
            case nil:
                EmptyView()
            }
            if sources.cloudChiefs.count > 1 {
                ChiefPickerMenu(sources: sources, newChief: newChiefAction) {
                    Text("Other Chiefs")
                }
            }
        }
        .font(.footnote.weight(.semibold))
        .buttonStyle(.borderless)
        .disabled(sources.isChanging)
        if sources.isChanging {
            ProgressView().controlSize(.small)
        }
        if let error = sources.changeError {
            Text(error)
                .font(.footnote)
                .foregroundStyle(Color(uiColor: .systemRed))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("home.chief.changeError")
        }
    }
}

/// One conversation row of Home from plain values: SwiftUI compares the
/// model and skips the row (its body and menu) when it did not change, so a
/// new list costs O(changed rows). `open` and `feed` only run actions.
struct HomeListRow: View, Equatable {
    struct Model: Equatable {
        var id: String
        var title: String
        var subtitle: String?
        var preview: String
        var stamp: String
        var isUnread: Bool
        var isMuted: Bool
        var isTyping: Bool
        var isPinned: Bool
        var avatar: String
        var isMacChief: Bool
        /// Where a tap goes.
        var route: HomeConversationRoute
    }

    let model: Model
    let open: (HomeConversationRoute) -> Void
    let feed: MacHomeFeed

    nonisolated static func == (a: Self, b: Self) -> Bool { a.model == b.model }

    var body: some View {
        let model = model
        Button { open(model.route) } label: {
            MessagesRow(title: model.title, subtitle: model.subtitle, preview: model.preview, stamp: model.stamp,
                        isUnread: model.isUnread, isMuted: model.isMuted, needsYou: false, isTyping: model.isTyping) { size in
                ChiefAvatar(text: model.avatar, size: size)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            HomeRowMenu(id: model.id, isMacChief: model.isMacChief, isPinned: model.isPinned, isUnread: model.isUnread, feed: feed)
        }
        .accessibilityIdentifier(model.isMacChief ? "home.chief.mac" : "home.row.\(model.id)")
    }
}

/// The Mac's row menu, the actions that are the person's list state:
/// Pin or Unpin, Mark as Read or Mark as Unread; Chief's row also calls Chief.
struct HomeRowMenu: View {
    let id: String
    let isMacChief: Bool
    let isPinned: Bool
    let isUnread: Bool
    let feed: MacHomeFeed

    var body: some View {
        if isMacChief { CallChiefItem() }
        Button(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin") {
            theme.haptics.selection()
            feed.setPinned(!isPinned, id)
        }
        if isUnread {
            Button("Mark as Read", systemImage: "message") { feed.markRead(id) }
        } else {
            Button("Mark as Unread", systemImage: "message.badge") { feed.setMarkedUnread(true, id) }
        }
    }
}

/// A live voice call with Chief (``ChiefCallLauncher``).
struct CallChiefItem: View {
    var body: some View {
        Button("Call Chief", systemImage: "phone") { ChiefCallLauncher.shared.call() }
            .accessibilityIdentifier("home.chief.call")
    }
}

/// One tile of Messages' pinned grid, as the Mac's Home draws it: a large
/// avatar, the name (the unread dot before it, the muted bell after it),
/// where a Chief runs, and a typing or preview bubble above the avatar. A
/// button of its own: a tap opens this tile only.
struct HomeTile: View, Identifiable {
    let id: String
    let avatar: String
    let name: String
    let detail: String?
    let unread: Bool
    let working: Bool
    /// The unread preview, shown in a bubble over the avatar.
    let bubble: String?
    let muted: Bool
    let identifier: String
    let open: () -> Void
    let menu: AnyView?

    @ScaledMetric(relativeTo: .body) private var scaledClearance: CGFloat = 10
    private var bubbleClearance: CGFloat { min(max(scaledClearance, 10), 18) }
    private var showsBubble: Bool { working || bubble != nil }

    var body: some View {
        Button(action: open) {
            tile
                .frame(maxWidth: .infinity)
                .padding(.top, showsBubble ? 14 + bubbleClearance : 14)
                .padding(.bottom, 10)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu { if let menu { menu } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(identifier)
        .animation(theme.motion.snappy.animation, value: working)
        .animation(theme.motion.snappy.animation, value: bubble)
    }

    private var accessibilityLabel: Text {
        let name = detail.map { "\(self.name), \($0)" } ?? self.name
        if working { return Text("\(name), typing") }
        if let bubble { return Text("\(name), \(bubble)") }
        return Text("\(name), pinned")
    }

    private var tile: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                ChiefAvatar(text: avatar, size: 72)
                if working {
                    TypingBubble()
                        .offset(x: -14, y: -18)
                        .transition(.scale(scale: 0.6, anchor: .bottomTrailing).combined(with: .opacity))
                } else if let bubble {
                    Text(bubble)
                        .font(.caption2)
                        // A glance, not the message: it stays a small bubble at accessibility sizes too.
                        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                        .lineLimit(2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: 100, alignment: .leading)
                        .background(theme.colors.surfaceRaised.color, in: .rect(cornerRadius: 12, style: .continuous))
                        .offset(x: -24, y: -26)
                        .transition(.scale(scale: 0.6, anchor: .bottomTrailing).combined(with: .opacity))
                }
            }
            HStack(spacing: 4) {
                if unread {
                    Circle().fill(theme.colors.label.color).frame(width: 8, height: 8)
                }
                Text(name)
                    .font(.footnote)
                    .foregroundStyle(theme.colors.label.color)
                    .lineLimit(1)
                if muted {
                    Image(systemName: "bell.slash.fill")
                        .font(.caption2)
                        .foregroundStyle(theme.colors.label3.color)
                        .accessibilityLabel("Alerts hidden")
                }
            }
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(theme.colors.label2.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

/// A conversation of the Mac's Home list other than the Mac Chief's, over
/// its own `chief` channel to that Mac (``MacHomeFeed/session(for:)``).
struct MacConversationScreen: View {
    struct SessionKey: Hashable {
        let route: MacConversationRoute
        let epoch: Int
        let retry: Int
        // First-open failures have no cached session, so reconnect need not bump the epoch.
        let hasRows: Bool
        let homeProblem: String?
    }

    let route: MacConversationRoute
    let feed: MacHomeFeed
    let macID: String?
    let reconnect: ((String) async -> Void)?
    @State private var loader = MacConversationLoader()

    var body: some View {
        Group {
            if let session = loader.session {
                ChiefConversationScreen(session: session)
            } else if loader.failed {
                ContentUnavailableView {
                    Label(route.title, systemImage: "bubble.left.and.exclamationmark.bubble.right")
                } description: {
                    Text(RecoveryMessage.conversation.text)
                } actions: {
                    RetryButton {
                        await loader.retry(macID: macID, reconnect: reconnect, refresh: { await feed.refresh() })
                    }
                    .accessibilityIdentifier("home.conversation.retry")
                }
            } else {
                ProgressView().accessibilityIdentifier("home.conversation.loading")
            }
        }
        // Owned by the screen: a retry button disappearing cannot cancel the load it requested.
        .task(id: SessionKey(route: route, epoch: feed.sessionEpoch, retry: loader.retryID,
                             hasRows: feed.rows != nil, homeProblem: feed.problem)) {
            await loader.load { try await feed.session(for: route) }
        }
    }
}

/// A Messages conversation row: the unread (or needs-you) gutter, the
/// avatar, the title with the date and chevron, and a two-line preview. At
/// accessibility text sizes it stacks as Messages does (SPEC 1.7): the
/// title on its own lines, then the date and chevron, then the preview.
struct MessagesRow<Avatar: View>: View {
    let title: String
    /// The agent, for VoiceOver (F5): the avatar mark says it to the eye
    /// only. nil when the title already names it ("cmux · Codex").
    var agent: String?
    /// The agent and its Mac ("Codex · Aziz's MacBook Pro"), under the title.
    var subtitle: String?
    let preview: String
    let stamp: String
    let isUnread: Bool
    let isMuted: Bool
    let needsYou: Bool
    /// The Chief types or runs: the typing bubble stands in for the preview, as on the Mac.
    var isTyping = false
    @ViewBuilder let avatar: (CGFloat) -> Avatar
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var scaledAvatar: CGFloat = 45

    /// 45 pt at Large, scaled with the text, at most 64 pt.
    private var avatarSize: CGFloat { min(max(scaledAvatar, 45), 64) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            gutter
                .frame(width: 26, height: avatarSize)
            avatar(avatarSize)
                .padding(.trailing, 12)
            Group {
                if typeSize.isAccessibilitySize { stacked } else { standard }
            }
            // The separator starts under the text, as in Messages.
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
        .padding(.vertical, 12)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// "Needs you, cmux, Claude, 1:46 AM, Refactor transport layer".
    private var accessibilityText: String {
        var parts: [String] = []
        if isUnread { parts.append(String(localized: "Unread")) } else if needsYou { parts.append(String(localized: "Needs you")) }
        parts.append(title)
        if let subtitle { parts.append(subtitle) } else if let agent { parts.append(agent) }
        parts.append(stamp)
        if isTyping { parts.append(String(localized: "Typing")) }
        if !preview.isEmpty { parts.append(preview) }
        if isMuted { parts.append(String(localized: "Alerts hidden")) }
        return parts.joined(separator: ", ")
    }

    /// Messages keeps a gutter for the unread dot. Unread wins; then the
    /// needs-you dot; then the muted bell.
    @ViewBuilder private var gutter: some View {
        if isUnread {
            Circle().fill(theme.colors.label.color).frame(width: 10, height: 10)
                .accessibilityLabel("Unread")
        } else if needsYou {
            Circle().fill(theme.colors.needsYou.color).frame(width: 10, height: 10)
                .accessibilityLabel("Needs you")
        } else if isMuted {
            Image(systemName: "bell.slash.fill").font(.system(size: 10)).foregroundStyle(theme.colors.label2.color)
                .accessibilityLabel("Alerts hidden")
        } else {
            Color.clear
        }
    }

    private var titleText: some View {
        Text(title).font(.body.weight(.semibold))
    }

    @ViewBuilder private var subtitleText: some View {
        if let subtitle, !subtitle.isEmpty {
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(theme.colors.label.color)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var dateAndChevron: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(stamp)
                .font(.subheadline)
                .foregroundStyle(theme.colors.label2.color)
                .lineLimit(1)
                .fixedSize()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(theme.colors.label3.color)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private func previewText(lines: Int) -> some View {
        if isTyping {
            TypingBubble().scaleEffect(0.8, anchor: .leading)
        } else {
            Text(preview.isEmpty ? " " : preview)
                .font(.subheadline)
                .foregroundStyle(theme.colors.label2.color)
                .lineLimit(lines, reservesSpace: true)
        }
    }

    private var standard: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                titleText.lineLimit(1)
                Spacer(minLength: 4)
                dateAndChevron
            }
            subtitleText
            previewText(lines: 2)
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 2) {
            titleText
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            dateAndChevron
            subtitleText
            Text(preview.isEmpty ? " " : preview)
                .font(.subheadline)
                .foregroundStyle(theme.colors.label2.color)
                .lineLimit(3)
        }
    }
}

/// Contacts' monogram gradient as Messages draws it (measured from the
/// iOS 26 / 27 simulator: a muted slate, lighter at the top).
let monogramGradient = LinearGradient(
    colors: [Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.33, green: 0.32, blue: 0.45, alpha: 1) : UIColor(red: 0.66, green: 0.68, blue: 0.75, alpha: 1) }),
             Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.19, green: 0.18, blue: 0.27, alpha: 1) : UIColor(red: 0.53, green: 0.55, blue: 0.62, alpha: 1) })],
    startPoint: .top, endPoint: .bottom
)

/// Messages' monogram: initials on the contact gradient circle.
struct Monogram: View {
    let text: String
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(monogramGradient)
            .overlay {
                Text(text).font(.system(size: size * 0.4, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Chief's avatar: its avatar text (the Mac's, else "C") white on the
/// monogram gradient, the one drawing of Chief everywhere (SPEC 2).
struct ChiefAvatar: View {
    let text: String
    let size: CGFloat

    var body: some View {
        Monogram(text: text, size: size)
    }
}

/// The three-dot typing bubble Messages shows on a pinned avatar. The dots
/// pulse with a Core Animation animation on the render server: no per-frame
/// body while a Chief types (it was a `TimelineView(.animation)` per bubble).
struct TypingBubble: View {
    var body: some View {
        TypingDots()
            .frame(width: TypingDotsView.width, height: TypingDotsView.dot)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(theme.colors.surfaceRaised.color, in: .capsule)
            .accessibilityLabel("Typing")
    }
}

private struct TypingDots: UIViewRepresentable {
    func makeUIView(context: Context) -> TypingDotsView { TypingDotsView() }
    func updateUIView(_ view: TypingDotsView, context: Context) {}
}

/// Three 7 pt dots 4 pt apart in `label2`; dot i's opacity is
/// 0.35 + 0.65 * max(0, sin(4t - 0.8i)), every bubble in step (the phase from the clock).
final class TypingDotsView: UIView {
    static let dot: CGFloat = 7
    static let spacing: CGFloat = 4
    static let width = dot * 3 + spacing * 2
    /// One period of sin(4t).
    private static let period = Double.pi / 2
    private let dots = (0..<3).map { _ in CALayer() }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        for (index, dot) in dots.enumerated() {
            dot.frame = CGRect(x: CGFloat(index) * (Self.dot + Self.spacing), y: 0, width: Self.dot, height: Self.dot)
            dot.cornerRadius = Self.dot / 2
            layer.addSublayer(dot)
        }
        recolor()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: TypingDotsView, _) in
            view.recolor()
        }
        // The system drops layer animations while the app is in the background.
        NotificationCenter.default.addObserver(self, selector: #selector(restartPulse),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(restartPulse),
                                               name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize { CGSize(width: Self.width, height: Self.dot) }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { startPulse() }
    }

    private func recolor() {
        let color = theme.colors.label2.uiColor.resolvedColor(with: traitCollection).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for dot in dots { dot.backgroundColor = color }
        CATransaction.commit()
    }

    @objc private func restartPulse() { startPulse() }

    private func startPulse() {
        let samples = 24
        let values = (0...samples).map { step -> Double in
            0.35 + 0.65 * max(0, sin(Double(step) / Double(samples) * 2 * .pi))
        }
        let keyTimes = (0...samples).map { NSNumber(value: Double($0) / Double(samples)) }
        // Reduce Motion: three still dots (the row's typing state stays readable without motion).
        if UIAccessibility.isReduceMotionEnabled {
            for dot in dots {
                dot.removeAnimation(forKey: "pulse")
                dot.opacity = 0.6
            }
            return
        }
        let phase = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period)
        for (index, dot) in dots.enumerated() {
            dot.opacity = 0.35
            // motion: allow the typing indicator itself, as the Mac draws it; Reduce Motion shows still dots (above).
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = values
            pulse.keyTimes = keyTimes
            pulse.duration = Self.period
            pulse.repeatCount = .infinity
            pulse.isRemovedOnCompletion = false
            // sin(4t - 0.8i) is sin(4(t - 0.2i)): dot i runs 0.2 s behind.
            var offset = (phase - 0.2 * Double(index)).truncatingRemainder(dividingBy: Self.period)
            if offset < 0 { offset += Self.period }
            pulse.timeOffset = offset
            dot.add(pulse, forKey: "pulse")
        }
    }
}

/// The account's Cloud Chiefs, the open one checked, and New Chief.
struct ChiefPickerItems: View {
    let sources: ChiefSources
    var newChief: (() -> Void)?

    var body: some View {
        Section("Cloud Chiefs") {
            ForEach(sources.cloudChiefs.filter { $0.mainConversation != nil }, id: \.id) { chief in
                Button {
                    sources.select(chief)
                } label: {
                    if chief.id == sources.cloudChief?.id {
                        Label(Self.name(chief), systemImage: "checkmark")
                    } else {
                        Text(Self.name(chief))
                    }
                }
            }
            if let newChief {
                Button("New Chief", systemImage: "plus", action: newChief)
            }
        }
    }

    static func name(_ chief: CloudChief) -> String {
        chief.displayName.isEmpty ? String(localized: "Chief") : chief.displayName
    }
}

/// ``ChiefPickerItems`` as a menu button.
struct ChiefPickerMenu<MenuLabel: View>: View {
    let sources: ChiefSources
    var newChief: (() -> Void)?
    @ViewBuilder let label: () -> MenuLabel

    var body: some View {
        Menu {
            ChiefPickerItems(sources: sources, newChief: newChief)
        } label: {
            label()
        }
        .accessibilityIdentifier("home.chief.picker")
    }
}
#endif
