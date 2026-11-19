#if os(iOS)
import CmuxConversationCore
import Foundation

/// One item of Home's list (``ConversationsHome`` on the shared ``PagedList``): plain values, so
/// the list redraws an item only when its value changed (a Chief that starts typing redraws its
/// row, nothing else) and never animates the whole list for one row's change.
enum HomeItem: Identifiable, Equatable, Sendable {
    /// The pinned grid, in the owner's pin order.
    case tiles([HomeTileModel])
    /// New Chief's Create was tapped: the new Chief with a spinner, until the read after it lands.
    case creating(name: String, tag: String?)
    /// The Cloud Chief's brain is off: say so and offer Turn On.
    case offCard(HomeOffCardModel)
    /// The Cloud Chief could not take the pin: say why.
    case cloudStatus(HomeCloudStatusModel)
    /// A refused switch or create while the Cloud Chief is open.
    case changeError(String)
    /// A row of the Mac's list.
    case row(HomeRowModel)
    /// The Cloud Chief, or the Mac Chief before the Mac's list arrives.
    case session(HomeSessionModel)
    /// Nothing kept while the list is not live: Workspaces' empty state for the same Mac.
    case problem(HomeConnectionStatus.Empty, isRetrying: Bool)
    /// The list is on its way: a spinner and a line.
    case note(text: String, identifier: String)
    /// Show Hidden Conversations, with the hidden count.
    case showHidden(Int)
    /// No Conversations, or No Results for a search.
    case empty(searching: Bool)

    var id: String {
        switch self {
        case .tiles: "home:tiles"
        case .creating: "home:creating"
        case .offCard: "home:offCard"
        case .cloudStatus: "home:cloudStatus"
        case .changeError: "home:changeError"
        case let .row(model): model.id
        case let .session(model): model.place == .cloud ? "cloud-chief" : "mac-chief"
        case .problem: "home:problem"
        case let .note(_, identifier): "home:\(identifier)"
        case .showHidden: "home:showHidden"
        case .empty: "home:empty"
        }
    }
}

/// One conversation row of Home from plain values (``HomeListRow``).
struct HomeRowModel: Equatable, Sendable {
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

/// One tile of the pinned grid from plain values (``HomeTile``).
struct HomeTileModel: Identifiable, Equatable, Sendable {
    var id: String
    var avatar: String
    var name: String
    var detail: String?
    var unread: Bool
    var working: Bool
    /// The unread preview, shown in a bubble over the avatar.
    var bubble: String?
    var muted: Bool
    var identifier: String
    var isMacChief: Bool
    /// Where a tap goes.
    var route: HomeConversationRoute
}

/// A Chief the phone holds itself as a row (the Cloud Chief, or the Mac Chief before the list arrives).
struct HomeSessionModel: Equatable, Sendable {
    var place: ChiefRoute.Place
    var name: String
    var tag: String?
    var preview: String
    var stamp: String
    var isUnread: Bool
    var isMuted: Bool
    var needsYou: Bool
    var isTyping: Bool
    var avatar: String
    /// The session has its conversation (Hide Alerts is offered).
    var hasConversation: Bool
    var identifier: String
}

/// The Cloud Chief's off card's values (``ChiefOffCardView``).
struct HomeOffCardModel: Equatable, Sendable {
    var card: ChiefOffCard
    var name: String
    var showsPicker: Bool
    var isChanging: Bool
    /// This service makes Chiefs (the picker offers New Chief).
    var canCreateChief: Bool
}

/// Why the Cloud Chief could not take the pin, and what the person can do.
struct HomeCloudStatusModel: Equatable, Sendable {
    var text: String
    var action: ChiefSources.CloudAction?
    var showsPicker: Bool
    var isChanging: Bool
    var error: String?
    /// This service makes Chiefs (the picker offers New Chief).
    var canCreateChief: Bool
}

/// Home's items, built once per change of what they show (verify/listperf/, `home-live`): a body
/// pass whose inputs did not change returns the items it built last, and a change rebuilds the
/// row models of only the rows whose value changed (a Chief typing formats one time stamp and
/// makes one tag, not one per row), so the list underneath compares values and redraws one row.
@MainActor
final class HomeListItems {
    /// What every row model reads besides its own row: a change rebuilds every row model.
    struct RowContext: Equatable, Sendable {
        /// Where a Chief runs ("Cloud", or the Home Mac's name), the tag after its name.
        var macTag: String?
        /// The Mac Chief's own conversation, as its session holds it.
        var macChiefConversation: String?
        /// The Mac Chief's conversation as the Mac's list names it (before the session has it).
        var macChiefListID: String?
        var macAvatar: String
        var cloudReady: Bool
        /// The day the time stamps are relative to ("Yesterday", a weekday).
        var day: Date
        /// The locale the time stamps are written in.
        var locale = Locale.current.identifier
    }

    /// Everything else the items show, besides the list's rows.
    struct Extras: Equatable, Sendable {
        var searching = false
        /// The one status item under the grid (creating, off card, Cloud status or change error).
        var status: HomeItem?
        /// The Cloud Chief's row, placed among the unpinned rows by its newest message.
        var cloud: HomeSessionModel?
        var cloudAt = Date.distantPast
        /// The Mac Chief's row before the Mac's list arrives, placed the same way.
        var macChief: HomeSessionModel?
        var macChiefAt = Date.distantPast
        /// The items under the rows: the problem state or a loading note, then Show Hidden.
        var trailing: [HomeItem] = []
        /// "No Conversations" (or "No Results") may show when nothing else does.
        var mayShowEmpty = false
    }

    private struct Built {
        var row: MacHomeRow
        var model: HomeRowModel
        var tile: HomeTileModel
    }

    private var last: (list: Int, context: RowContext, extras: Extras, items: [HomeItem])?
    private var ownSeen: (query: String, hidden: Int, assemblies: Int, own: Bool)?
    private var built: [String: Built] = [:]
    private var builtContext: RowContext?
    /// Row models built (tests: one per changed row, none for a pass with nothing new).
    private(set) var rowModelBuilds = 0
    /// Item lists assembled (tests: none for a pass with nothing new).
    private(set) var assemblies = 0

    init() {}

    /// Whether the items' last change was the person's own: the search changed, or hidden rows were
    /// hidden or shown again (``PagedList/pagedCountsArrivals(_:)``: the rows it brings above the
    /// top are not new). Ask after ``items(_:listRevision:context:extras:)``: a body pass that
    /// assembled nothing new gets the same answer as the pass that did.
    func isOwnChange(query: String, hidden: Int) -> Bool {
        if let seen = ownSeen, seen.query == query, seen.hidden == hidden, seen.assemblies == assemblies { return seen.own }
        let own = ownSeen.map { $0.query != query || $0.hidden != hidden } ?? false
        ownSeen = (query, hidden, assemblies, own)
        return own
    }

    /// Home's items for `list` (whose ``MacHomeList/Memo/revision`` is `listRevision`).
    func items(_ list: MacHomeList, listRevision: Int, context: RowContext, extras: Extras) -> [HomeItem] {
        if let last, last.list == listRevision, last.context == context, last.extras == extras { return last.items }
        assemblies += 1
        if builtContext != context {
            built = [:]
            builtContext = context
        }
        var stamp: MessagesStamp?
        var next: [String: Built] = [:]
        next.reserveCapacity(list.pinned.count + list.rows.count)
        func models(_ row: MacHomeRow) -> Built {
            if let held = built[row.id], held.row == row {
                next[row.id] = held
                return held
            }
            if stamp == nil { stamp = MessagesStamp(now: max(Date(), context.day)) }
            let made = Self.build(row, context: context, stamp: stamp ?? MessagesStamp())
            rowModelBuilds += 1
            next[row.id] = made
            return made
        }
        var items: [HomeItem] = []
        items.reserveCapacity(list.rows.count + 6)
        let tiles = list.pinned.map { models($0).tile }
        if !tiles.isEmpty { items.append(.tiles(tiles)) }
        if !extras.searching, let status = extras.status { items.append(status) }
        let first = items.count
        for row in list.rows { items.append(.row(models(row).model)) }
        func place(_ item: HomeItem, at date: Date) {
            let index = items[first...].firstIndex { entry in
                guard case let .row(model) = entry, let row = next[model.id]?.row else { return false }
                return !row.isPinned && row.activityAt < date
            }
            items.insert(item, at: index ?? items.endIndex)
        }
        if let mac = extras.macChief { place(.session(mac), at: extras.macChiefAt) }
        if let cloud = extras.cloud { place(.session(cloud), at: extras.cloudAt) }
        let entries = items.count - first
        items += extras.trailing
        if tiles.isEmpty, entries == 0, extras.mayShowEmpty { items.append(.empty(searching: extras.searching)) }
        built = next
        last = (listRevision, context, extras, items)
        return items
    }

    /// A row's models: its list row and its tile, as the Mac's Home draws them.
    private static func build(_ row: MacHomeRow, context: RowContext, stamp: MessagesStamp) -> Built {
        let macChief = isMacChief(row.id, context: context)
        let tag: String? = row.kind == .chief ? chiefTag(main: !context.cloudReady && macChief, place: context.macTag) : nil
        let avatar = macChief ? context.macAvatar : homeInitials(row.title)
        let route: HomeConversationRoute = macChief
            ? .chief(.mac) : .mac(MacConversationRoute(conversationID: row.id, chief: row.chief, title: row.title))
        let model = HomeRowModel(id: row.id, title: row.title, subtitle: tag, preview: row.preview,
                                 stamp: row.activityAt > .distantPast ? stamp.string(for: row.activityAt) : "",
                                 isUnread: row.unreadCount > 0, isMuted: row.isMuted, isTyping: row.isWorking,
                                 isPinned: row.isPinned, avatar: avatar, isMacChief: macChief, route: route)
        let tile = HomeTileModel(id: row.id, avatar: avatar, name: row.title, detail: tag,
                                 unread: row.unreadCount > 0, working: row.isWorking,
                                 bubble: row.unreadCount > 0 && !row.preview.isEmpty ? row.preview : nil,
                                 muted: row.isMuted, identifier: macChief ? "home.chief.mac" : "home.pin.\(row.id)",
                                 isMacChief: macChief, route: route)
        return Built(row: row, model: model, tile: tile)
    }

    /// The Mac Chief's own conversation: the one its session holds, else the one the Mac's list names.
    static func isMacChief(_ id: String, context: RowContext) -> Bool {
        id == context.macChiefConversation || (context.macChiefConversation == nil && id == context.macChiefListID)
    }

    /// The tag after a Chief's name, as the Mac's list draws it (`HomeChiefRoster.tag`): "Main" for
    /// the main Chief, then where it runs.
    static func chiefTag(main: Bool, place: String?) -> String? {
        let parts = [main ? String(localized: "Main") : nil, place].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }
}
#endif
