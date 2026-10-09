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

    public var id: String
    public var title: String
    public var people: [Person]
    public var preview: String
    /// The newest message's sender in a group (nil: me, or a 1:1).
    public var previewSender: String?
    public var lastAt: Date
    public var unreadCount: Int
    public var pinned: Bool
    public var muted: Bool
    public var typing: Bool

    public init(id: String, title: String, people: [Person], preview: String, previewSender: String?, lastAt: Date,
                unreadCount: Int, pinned: Bool, muted: Bool = false, typing: Bool = false) {
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

    /// MessagesLab's summary. `version` comes from the content, so a changed
    /// conversation gets a new bitmap and an unchanged one keeps its own.
    var summary: ConversationSummary {
        let members = people.map { SummaryParticipant(id: $0.id, displayName: $0.name, avatar: .monogram($0.initials)) }
        let avatar: AvatarSpec = members.count > 1 ? .group(members.prefix(4).map(\.avatar))
            : members.first?.avatar ?? .monogram(String(title.prefix(1)).uppercased())
        return ConversationSummary(id: id, title: title, participants: members, avatar: avatar, preview: preview,
                                   previewSender: previewSender, lastAt: lastAt, unreadCount: unreadCount, pinned: pinned,
                                   muted: muted, typing: typing, lastReaction: nil, version: hashValue)
    }
}

/// MessagesLab's conversation list (search, the pinned grid, the rows) for
/// the cmux-next Home page. The host owns the width (`minimumWidth`,
/// `preferredWidth`) and the data: it calls `show` after every change and
/// answers `onSelect` and `onSetPinned`.
@MainActor
public final class CmuxSidebarView: NSView {
    public var onSelect: (String?) -> Void = { _ in }
    public var onSetPinned: (Bool, String) -> Void = { _, _ in }
    /// Mark as Read (true) on an unread conversation, Mark as Unread (false) on a read one.
    public var onSetRead: (Bool, String) -> Void = { _, _ in }
    /// Host items for a conversation's context menu after Pin and Read (MessagesLab v1.1
    /// `menuItemsFor`; Hide Alerts and Delete are left out until cmux can do them).
    public var menuItems: (String) -> [NSMenuItem] = { _ in [] }
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

    let controller = SidebarController()
    private let link = SidebarLink()
    public private(set) var entries: [CmuxSidebarEntry] = []
    public private(set) var pinnedOrder: [String] = []

    public override init(frame: NSRect) {
        // MessagesLab v1.1: the sidebar's strings come from its own catalog in this package's bundle.
        SidebarLocalization.bundle = .module
        super.init(frame: frame)
        link.owner = self
        controller.dataSource = link
        controller.delegate = link
        controller.searchProvider = link
        controller.view.frame = bounds
        controller.view.autoresizingMask = [.width, .height]
        addSubview(controller.view)
        setAccessibilityIdentifier("cmux.home.sidebar")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The compact (avatar-only) list's width and the width the list is designed for.
    public var minimumWidth: CGFloat { controller.minimumWidth }
    public var preferredWidth: CGFloat { controller.preferredWidth ?? 320 }
    public var selectedID: String? { controller.selectedID }

    /// Shows `entries` (newest first, pinned included) with `pinned` in tile order.
    public func show(_ entries: [CmuxSidebarEntry], pinned: [String]) {
        guard entries != self.entries || pinned != pinnedOrder else { return }
        self.entries = entries
        pinnedOrder = pinned
        controller.reloadData()
    }

    /// In the compact (avatar-only) list the search field is hidden rather
    /// than clipped to a few letters, and a search in progress ends, so no
    /// hidden filter stays on the rows. (Upstream ask: Messages' compact search.)
    public override func layout() {
        super.layout()
        let compact = bounds.width < SidebarMetrics.compactBelow
        guard controller.searchField.isHidden != compact else { return }
        controller.searchField.isHidden = compact
        if compact, !controller.searchField.stringValue.isEmpty {
            controller.searchField.stringValue = ""
            controller.setQuery("")
        }
    }

    /// The search field's text.
    public var searchQuery: String { controller.searchField.stringValue }

    /// True while the list is too narrow for the search field.
    public var searchHidden: Bool { controller.searchField.isHidden }

    /// Selects `id` without reporting it (the page already shows it).
    public func select(_ id: String?) {
        guard id != controller.selectedID else { return }
        controller.select(id, notify: false)
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
private final class SidebarLink: @preconcurrency SidebarDataSource, @preconcurrency SidebarDelegate, @preconcurrency SidebarSearchProvider {
    weak var owner: CmuxSidebarView?

    func sidebarSnapshot(_ sidebar: SidebarController) -> ConversationListSnapshot {
        owner?.snapshot ?? ConversationListSnapshot(items: [], pinned: [])
    }

    func sidebar(_ sidebar: SidebarController, didSelect id: ConversationID?) { owner?.onSelect(id) }
    func sidebar(_ sidebar: SidebarController, setPinned pinned: Bool, for id: ConversationID) { owner?.onSetPinned(pinned, id) }
    func sidebar(_ sidebar: SidebarController, setRead read: Bool, for id: ConversationID) { owner?.onSetRead(read, id) }
    // Pin, and Mark as Read on an unread conversation or Mark as Unread on a read one (the
    // controller picks the title from the entry's unread count; the host keeps the mark). Hide
    // Alerts and Delete need owner support first: no item that does nothing.
    func sidebar(_ sidebar: SidebarController, actionsFor id: ConversationID) -> SidebarActions {
        owner?.entries.contains { $0.id == id } == true ? [.pin, .markRead] : [.pin]
    }
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
