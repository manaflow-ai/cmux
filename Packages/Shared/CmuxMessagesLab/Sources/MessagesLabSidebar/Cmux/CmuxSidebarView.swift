public import AppKit

/// One conversation for MessagesLab's sidebar (`SidebarController`, vendored
/// byte-identical: appkit-native/SIDEBAR.md "The seam for cmux-next (v1)").
/// The public face of `ConversationSummary`, which has no access modifiers upstream.
public struct CmuxSidebarEntry: Hashable, Sendable {
    /// A participant other than me.
    public struct Person: Hashable, Sendable {
        public var id: String
        public var name: String
        public var initials: String

        public init(id: String, name: String, initials: String) {
            self.id = id
            self.name = name
            self.initials = initials
        }
    }

    /// The conversation's own avatar, drawn instead of its people's (the
    /// Home Chief's picture, emoji or initials).
    public enum Avatar: Hashable, Sendable {
        /// One or two letters on Messages' grey gradient.
        case monogram(String)
        /// A picture file (a `file:` URL string).
        case image(String)
        /// An emoji on the grey disc.
        case emoji(String)
    }

    public var id: String
    public var title: String
    public var people: [Person]
    /// Drawn instead of the people's avatars; nil draws theirs.
    public var avatar: Avatar?
    public var preview: String
    /// The newest message's sender in a group (nil: me, or a 1:1).
    public var previewSender: String?
    public var lastAt: Date
    public var unreadCount: Int
    public var pinned: Bool
    public var muted: Bool
    public var typing: Bool
    /// Sidebar v1.2: the sender is a contact (the Known and Unknown Senders filters).
    public var knownSender: Bool
    /// Sidebar v1.2: filtered as spam (only the Spam filter shows it).
    public var spam: Bool
    /// Sidebar v1.2: deleted at this time (only Recently Deleted shows it).
    public var deletedAt: Date?
    /// A short tag after the name (the engine a Home Chief runs on, "UniiChat"); nil shows none.
    /// The vendored row draws only the name, so the tag is part of the name it is given.
    public var badge: String?
    /// How the conversation's own `avatar` moves: nil stands still (``SidebarAvatarMotion``).
    public var avatarMotion: AvatarMotion?

    /// A moving avatar: a Chief's slow idle loop, livelier while it works.
    public enum AvatarMotion: Hashable, Sendable {
        case idle
        case working
    }

    public init(id: String, title: String, people: [Person], preview: String, previewSender: String?, lastAt: Date,
                unreadCount: Int, pinned: Bool, muted: Bool = false, typing: Bool = false,
                knownSender: Bool = true, spam: Bool = false, deletedAt: Date? = nil, avatar: Avatar? = nil, badge: String? = nil,
                avatarMotion: AvatarMotion? = nil) {
        self.avatar = avatar
        self.avatarMotion = avatarMotion
        self.badge = badge
        self.knownSender = knownSender
        self.spam = spam
        self.deletedAt = deletedAt
        self.id = id
        self.title = title
        self.people = people
        self.preview = preview
        self.previewSender = previewSender
        self.lastAt = lastAt
        self.unreadCount = unreadCount
        self.pinned = pinned
        self.muted = muted
        self.typing = typing
    }

    /// The name the row draws: the title, then the badge after a middle dot.
    var shownTitle: String {
        guard let badge, !badge.isEmpty else { return title }
        return title + " \u{00B7} " + badge
    }

    /// MessagesLab's summary. `version` comes from the content, so a changed
    /// conversation gets a new bitmap and an unchanged one keeps its own.
    var summary: ConversationSummary {
        let members = people.map { SummaryParticipant(id: $0.id, displayName: $0.name, avatar: .monogram($0.initials)) }
        let own: AvatarSpec? = switch self.avatar {
        case .monogram(let text): .monogram(text)
        case .image(let path): .image(path)
        case .emoji(let text): .emoji(text)
        case nil: nil
        }
        let avatar: AvatarSpec = own ?? (members.count > 1 ? .group(members.prefix(4).map(\.avatar))
            : members.first?.avatar ?? .monogram(String(title.prefix(1)).uppercased()))
        var s = ConversationSummary(id: id, title: shownTitle, participants: members, avatar: avatar, preview: preview,
                                    previewSender: previewSender, lastAt: lastAt, unreadCount: unreadCount, pinned: pinned,
                                    muted: muted, typing: typing, lastReaction: nil, version: hashValue)
        s.knownSender = knownSender
        s.spam = spam
        s.deletedAt = deletedAt
        s.avatarMotion = own == nil ? nil : avatarMotion.map { $0 == .working ? .working : .idle }
        return s
    }
}

/// MessagesLab's conversation list (search, the pinned grid, the rows) for
/// the cmux-next Home page. The host owns the width (`minimumWidth`,
/// `preferredWidth`) and the data: it calls `show` after every change and
/// answers `onSelect` and `onSetPinned`.
@MainActor
public final class CmuxSidebarView: NSView {
    public var onSelect: (String?) -> Void = { _ in }
    /// The person opened a conversation (its id): a plain click on its row or tile, the selected
    /// one too, or Return on the highlighted one. Called after ``onSelect``; Up/Down and Command-,
    /// Shift- or Control-clicks only select. The host moves the keyboard into the conversation.
    public var onOpen: (String) -> Void = { _ in }
    public var onSetPinned: (Bool, String) -> Void = { _, _ in }
    /// A drag put a conversation at an index of the pinned grid (a new place, or a row pinned
    /// there). The host changes its order and calls `show` before returning, so the tiles land
    /// from where they were drawn. A tile dragged onto the list goes to `onSetPinned(false, _)`.
    public var onPlacePinned: (String, Int) -> Void = { _, _ in }
    /// Mark as Read (true) on an unread conversation, Mark as Unread (false) on a read one.
    public var onSetRead: (Bool, String) -> Void = { _, _ in }
    /// Host items for a conversation's context menu after Pin and Read (MessagesLab v1.1
    /// `menuItemsFor`; Hide Alerts and Delete are left out until cmux can do them).
    public var menuItems: (String) -> [NSMenuItem] = { _ in [] }
    /// Delete Conversation… (the row's menu, after the host's items) and a left swipe's Delete;
    /// nil: neither is offered. The host asks first and decides what a delete does.
    public var onDelete: ((String) -> Void)?
    /// An extra search section under the conversations for a query (nil: none), asked once
    /// per keystroke; a later keystroke cancels the answer.
    public var searchSection: (String) -> CmuxSidebarSearchSection? = { _ in nil }
    /// A row of the extra section was chosen (its id).
    public var onSelectSearchResult: (String) -> Void = { _ in }
    /// The unread dot (nil: the system blue) and the key-window selection (nil: the system's).
    public var unreadColor: NSColor? {
        get { controller.unreadColor }
        set { controller.unreadColor = newValue }
    }
    public var selectionColor: NSColor? {
        get { controller.selectionColor }
        set { controller.selectionColor = newValue }
    }

    /// Draws the selected row or pinned tile in a neutral grey in every window state, with the
    /// normal text colours and grey pinned names, instead of the system's blue selection
    /// (Messages' pinned grid look). Off by default (MessagesLab's look).
    public var neutralSelection: Bool {
        get { controller.neutralSelection }
        set { controller.neutralSelection = newValue }
    }
    /// The filter button, right of the search field, for the host's styling (its frame and menu
    /// stay the list's).
    public var filterButton: NSButton { controller.filterButton }
    /// The filter button's side when the host draws it as a round button (nil: MessagesLab's
    /// 26 pt accessory button with the circled glyph).
    public var roundFilterSide: CGFloat? {
        get { controller.roundFilterSide }
        set { controller.roundFilterSide = newValue }
    }

    let controller = SidebarController()
    private let link = SidebarLink()
    /// The hover x of the ``closableID`` row (CmuxSidebarRowClose.swift).
    private(set) lazy var rowClose = CmuxSidebarRowClose(list: self)

    /// The row that shows an x at its trailing edge while the pointer is over it, as Messages'
    /// New Message row does; nil (the default) shows it on no row. The avatar-only list and a
    /// pinned tile never show it.
    public var closableID: String? {
        get { rowClose.rowID }
        set { rowClose.rowID = newValue }
    }
    /// The ``closableID`` row's x was clicked (its id). The host removes the row.
    public var onClose: (String) -> Void {
        get { rowClose.onClose }
        set { rowClose.onClose = newValue }
    }
    /// The x's tooltip and accessibility label ("Close New Message").
    public var closeTitle: String {
        get { rowClose.button.toolTip ?? "" }
        set {
            rowClose.button.toolTip = newValue
            rowClose.button.setAccessibilityLabel(newValue)
        }
    }
    /// The list's scroll view, for the host's scroller style (cmux's scrollers are thin overlays).
    public var scrollView: NSScrollView { controller.scrollView }
    public private(set) var entries: [CmuxSidebarEntry] = []
    public private(set) var pinnedOrder: [String] = []

    public override init(frame: NSRect) {
        // MessagesLab v1.1: the sidebar's strings come from its own catalog in this package's bundle.
        SidebarLocalization.bundle = .module
        super.init(frame: frame)
        link.owner = self
        controller.availableFilters = Self.filters(filterSources)
        controller.dataSource = link
        controller.delegate = link
        controller.searchProvider = link
        controller.view.frame = bounds
        controller.view.autoresizingMask = [.width, .height]
        addSubview(controller.view)
        setAccessibilityIdentifier("cmux.home.sidebar")
        // Reduce Motion changes (the system setting or the host's pin) still or restart the typing
        // bubbles already pulsing (CmuxSidebarView+Motion.swift).
        motionObservers = observeReduceMotion()
        _ = rowClose
    }

    public override func layout() {
        super.layout()
        // A width change can make the list avatar-only (no x) or move the row's trailing edge.
        rowClose.refresh()
    }

    /// The Reduce Motion observers (weak: a closed view's turn is a no-op).
    private var motionObservers: [any NSObjectProtocol] = []

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Sidebar v1.2's filters whose data the host supplies (the entries' knownSender, spam and
    /// deletedAt). All Messages and Unread Messages always have data; a filter without a source
    /// is not offered, so the menu never shows a list that can only be empty. Home sets none yet:
    /// HomeStore has no contact, spam or deletion state.
    public struct FilterSources: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let senders = FilterSources(rawValue: 1 << 0)
        public static let spam = FilterSources(rawValue: 1 << 1)
        public static let recentlyDeleted = FilterSources(rawValue: 1 << 2)
    }
    public var filterSources: FilterSources = [] {
        didSet { if layoutHeader == nil { controller.availableFilters = Self.filters(filterSources) } }
    }
    static func filters(_ s: FilterSources) -> [SidebarFilter] {
        SidebarFilter.allCases.filter {
            switch $0 {
            case .all, .unread: return true
            case .knownSenders, .unknownSenders: return s.contains(.senders)
            case .spam: return s.contains(.spam)
            case .recentlyDeleted: return s.contains(.recentlyDeleted)
            }
        }
    }

    /// The compact (avatar-only) list's width and the width the list is designed for.
    public var minimumWidth: CGFloat { controller.minimumWidth }
    public var preferredWidth: CGFloat { controller.preferredWidth ?? 320 }
    /// Below this width the list shows avatars only (no names, previews or section headers).
    public static var compactBelow: CGFloat { SidebarMetrics.compactBelow }
    public var selectedID: String? { controller.selectedID }

    /// Shows `entries` (newest first, pinned included) with `pinned` in tile order.
    public func show(_ entries: [CmuxSidebarEntry], pinned: [String]) {
        guard entries != self.entries || pinned != pinnedOrder else { return }
        self.entries = entries
        pinnedOrder = pinned
        // The list's own reload motion (rows sliding to new places, a pin's fade) follows the
        // same gate as the pin drag: under Reduce Motion or the host's gate it shows at once.
        let listMotion = SidebarMotion.enabled
        if !Self.animatesMovement { SidebarMotion.enabled = false }
        defer { SidebarMotion.enabled = listMotion }
        controller.reloadData()
        rowClose.refresh()
    }

    /// The search field's text.
    public var searchQuery: String { controller.searchField.stringValue }

    /// The search field, for a host that draws the header itself (`layoutHeader`): its frame,
    /// look and focus are the host's; its text and search stay the list's.
    public var searchField: CmuxSidebarSearchField { controller.searchField }

    /// The view the header lives in (flipped, the list's full bounds): a host that lays out the
    /// header adds its own buttons here, next to the search field.
    public var headerView: NSView { controller.view }

    /// The host lays out the header: called with the header view's bounds on every layout, it
    /// places `searchField` and its own buttons and returns the y where the list starts. With
    /// it, MessagesLab's filter menu button is hidden (the host offers the filter); the search
    /// field never hides at any width. Nil keeps MessagesLab's header.
    public var layoutHeader: ((CGRect) -> CGFloat)? {
        didSet {
            controller.headerLayout = layoutHeader
            controller.availableFilters = layoutHeader == nil ? Self.filters(filterSources) : []
            controller.filterButton.isHidden = layoutHeader != nil || controller.availableFilters.count < 2
        }
    }

    /// Only unread conversations (Sidebar v1.2's Unread Messages filter); false shows all.
    public var unreadOnly: Bool {
        get { controller.filter == .unread }
        set { controller.filter = newValue ? .unread : .all }
    }

    /// Ends a search: the field empties and the list shows every conversation again.
    public func clearSearch() {
        guard !controller.searchField.stringValue.isEmpty else { return }
        controller.searchField.stringValue = ""
        controller.setQuery("")
    }

    /// The neutral selection's fill (a translucent theme tint); nil keeps the unemphasized grey.
    public var neutralSelectionFill: NSColor? {
        get { controller.neutralFill }
        set { controller.neutralFill = newValue }
    }

    /// The list's own strings, for a host's header buttons: Search, and the Unread Messages filter.
    public static var searchTitle: String { SidebarStrings.search }
    public static var unreadTitle: String { SidebarStrings.filterName(.unread) }

    /// Selects `id` without reporting it (the page already shows it).
    public func select(_ id: String?) {
        guard id != controller.selectedID else { return }
        controller.select(id, notify: false)
    }

    /// Each pinned tile's and list row's frame in window points from the top-left, in display
    /// order (automation: drive a pin drag through synthesized mouse events).
    public var itemFramesInWindow: [(id: String, pinned: Bool, frame: NSRect)] {
        guard let window else { return [] }
        let height = window.contentView?.bounds.height ?? window.frame.height
        let document = controller.document
        func top(_ r: CGRect) -> NSRect {
            let w = document.convert(r, to: nil)
            return NSRect(x: w.minX, y: height - w.maxY, width: w.width, height: w.height)
        }
        let tiles = controller.pinnedItems.enumerated().compactMap { t, i in
            SidebarController.element(controller.snapshot.items, i).map { ($0.id, true, top(controller.tileRect(t))) }
        }
        let rows = controller.rowItems.enumerated().compactMap { r, i in
            SidebarController.element(controller.snapshot.items, i).map { ($0.id, false, top(controller.rowRect(r))) }
        }
        return tiles + rows
    }

    var snapshot: ConversationListSnapshot { ConversationListSnapshot(items: entries.map(\.summary), pinned: pinnedOrder) }
}

/// One row of the host's search section (a teammate, for example).
public struct CmuxSidebarSearchResult: Hashable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var initials: String

    public init(id: String, title: String, subtitle: String = "", initials: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.initials = initials
    }
}

/// The host's search section: a title and its rows.
public struct CmuxSidebarSearchSection: Hashable, Sendable {
    public var title: String
    public var results: [CmuxSidebarSearchResult]

    public init(title: String, results: [CmuxSidebarSearchResult]) {
        self.title = title
        self.results = results
    }
}

/// The controller's data source, delegate and search provider (it holds them weakly).
@MainActor
private final class SidebarLink: @preconcurrency SidebarDataSource, @preconcurrency SidebarDelegate, @preconcurrency SidebarSearchProvider,
    @preconcurrency SidebarPinPlacing {
    weak var owner: CmuxSidebarView?

    func sidebarSnapshot(_ sidebar: SidebarController) -> ConversationListSnapshot {
        owner?.snapshot ?? ConversationListSnapshot(items: [], pinned: [])
    }

    func sidebar(_ sidebar: SidebarController, didSelect id: ConversationID?) { owner?.onSelect(id) }
    func sidebar(_ sidebar: SidebarController, didOpen id: ConversationID) { owner?.onOpen(id) }
    func sidebar(_ sidebar: SidebarController, setPinned pinned: Bool, for id: ConversationID) { owner?.onSetPinned(pinned, id) }
    func sidebar(_ sidebar: SidebarController, setRead read: Bool, for id: ConversationID) { owner?.onSetRead(read, id) }
    func sidebar(_ sidebar: SidebarController, place id: ConversationID, at index: Int) { owner?.onPlacePinned(id, index) }
    // v1.2: MessagesLab's own tile reorder reports its drop here; the same placement as a pin drag.
    func sidebar(_ sidebar: SidebarController, movePinned id: ConversationID, to index: Int) { owner?.onPlacePinned(id, index) }
    // Pin, and Mark as Read on an unread conversation or Mark as Unread on a read one (the
    // controller picks the title from the entry's unread count; the host keeps the mark). Hide
    // Alerts and Delete need owner support first: no item that does nothing.
    func sidebar(_ sidebar: SidebarController, actionsFor id: ConversationID) -> SidebarActions {
        guard let owner, owner.entries.contains(where: { $0.id == id }) else { return [.pin] }
        return owner.onDelete == nil ? [.pin, .markRead] : [.pin, .markRead, .delete]
    }
    func sidebar(_ sidebar: SidebarController, delete id: ConversationID) { owner?.onDelete?(id) }
    func sidebar(_ sidebar: SidebarController, menuItemsFor id: ConversationID) -> [NSMenuItem] { owner?.menuItems(id) ?? [] }

    func sidebar(_ sidebar: SidebarController, search request: SidebarSearchRequest) {
        guard !request.isCancelled, let section = owner?.searchSection(request.query), !section.results.isEmpty else {
            request.complete(nil)
            return
        }
        request.complete(SidebarSearchSection(title: section.title, results: section.results.map {
            SidebarSearchResult(id: $0.id, title: $0.title, subtitle: $0.subtitle, avatar: .monogram($0.initials))
        }))
    }
    func sidebar(_ sidebar: SidebarController, didSelectSearchResult id: String) { owner?.onSelectSearchResult(id) }
}

/// A context-menu item that runs a closure (the host's `menuItems`; MessagesLab's
/// `SidebarMenuItem` is not public).
public final class CmuxSidebarMenuItem: NSMenuItem {
    private let handler: () -> Void

    public init(title: String, image: NSImage? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        self.image = image
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
