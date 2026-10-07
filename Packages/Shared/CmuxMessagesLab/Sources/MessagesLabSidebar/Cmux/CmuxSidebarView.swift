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
    public var onSetRead: (Bool, String) -> Void = { _, _ in }

    private let controller = SidebarController()
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

    /// True while the list is too narrow for the search field.
    public var searchHidden: Bool { controller.searchField.isHidden }

    /// Selects `id` without reporting it (the page already shows it).
    public func select(_ id: String?) {
        guard id != controller.selectedID else { return }
        controller.select(id, notify: false)
    }

    var snapshot: ConversationListSnapshot { ConversationListSnapshot(items: entries.map(\.summary), pinned: pinnedOrder) }
}

/// The controller's data source and delegate (it holds both weakly).
@MainActor
private final class SidebarLink: @preconcurrency SidebarDataSource, @preconcurrency SidebarDelegate {
    weak var owner: CmuxSidebarView?

    func sidebarSnapshot(_ sidebar: SidebarController) -> ConversationListSnapshot {
        owner?.snapshot ?? ConversationListSnapshot(items: [], pinned: [])
    }

    func sidebar(_ sidebar: SidebarController, didSelect id: ConversationID?) { owner?.onSelect(id) }
    func sidebar(_ sidebar: SidebarController, setPinned pinned: Bool, for id: ConversationID) { owner?.onSetPinned(pinned, id) }
    func sidebar(_ sidebar: SidebarController, setRead read: Bool, for id: ConversationID) { owner?.onSetRead(read, id) }
}
