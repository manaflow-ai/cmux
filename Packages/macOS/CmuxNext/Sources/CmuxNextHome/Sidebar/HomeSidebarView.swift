public import AppKit
public import CmuxHomeCore
import CmuxNextDesign
import MessagesLabSidebar

/// The Home page's left column: MessagesLab's conversation list
/// (`CmuxSidebarView`, vendored byte-identical) drawing a `HomeSidebarModel`
/// with no background of its own: the window's material or background image
/// shows through, as behind the transcript. It owns no data: the page gives
/// it the model after every change and handles the choices.
public final class HomeSidebarView: NSView {
    public var onSelect: (ConversationID) -> Void = { _ in }
    public var onSetPinned: (Bool, ConversationID) -> Void = { _, _ in }
    /// A drag put a conversation at an index of the pinned grid (a new place, or a row pinned
    /// there); call `update` before returning so the tiles land smoothly.
    public var onPlacePinned: (ConversationID, Int) -> Void = { _, _ in }
    /// Mark as Read (the menu offers it only while the conversation has unread messages).
    public var onMarkRead: (ConversationID) -> Void = { _ in }
    /// The host's context-menu items for a conversation (Archive Chief on a Chief).
    public var menuItems: (ConversationID) -> [NSMenuItem] = { _ in [] }
    /// Teammates matching a query that have no DM yet (the list's extra search section).
    public var teammates: (String) -> [HomeContact] = { _ in [] }
    /// A teammate from the search section was chosen: start (or open) the DM.
    public var onStartTeammate: (HomeContact) -> Void = { _ in }
    public var onNewMessage: () -> Void = {}
    /// The compose button's right-click menu (New Chief, Invite), or nil for none.
    public var composeMenu: () -> NSMenu? = { nil }

    let list = CmuxSidebarView()
    /// Messages' compose button, in the strip above the search field.
    let compose = HomeComposeButton()
    public private(set) var model = HomeSidebarModel(rows: [], pins: HomePins(), me: nil)

    public override init(frame: NSRect) {
        super.init(frame: frame)
        list.frame = bounds
        list.autoresizingMask = [.width, .height]
        addSubview(list)
        compose.bezelStyle = .accessoryBarAction
        compose.isBordered = false
        compose.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: HomeConversationStrings.newMessage)
        compose.setAccessibilityLabel(HomeConversationStrings.newMessage)
        compose.setAccessibilityIdentifier("cmux.home.sidebar.compose")
        compose.toolTip = HomeConversationStrings.newMessage
        compose.target = self
        compose.action = #selector(newMessage)
        compose.owner = self
        addSubview(compose)
        list.onSelect = { [weak self] id in if let id { self?.onSelect(ConversationID(id)) } }
        list.onSetPinned = { [weak self] on, id in self?.onSetPinned(on, ConversationID(id)) }
        list.onPlacePinned = { [weak self] id, index in self?.onPlacePinned(ConversationID(id), index) }
        list.onSetRead = { [weak self] read, id in if read { self?.onMarkRead(ConversationID(id)) } }
        list.menuItems = { [weak self] id in self?.menuItems(ConversationID(id)) ?? [] }
        list.searchSection = { [weak self] query in
            guard let self else { return nil }
            let people = teammates(query)
            guard !people.isEmpty else { return nil }
            return CmuxSidebarSearchSection(title: HomeConversationStrings.teammatesSection, results: people.map {
                CmuxSidebarSearchResult(id: $0.id.rawValue, title: $0.name, initials: Self.initials($0.name))
            })
        }
        list.onSelectSearchResult = { [weak self] id in
            guard let self, let person = teammates(list.searchQuery).first(where: { $0.id.rawValue == id }) else { return }
            onStartTeammate(person)
        }
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The compact list's width and the width the list is designed for (MessagesLab's).
    public var minimumWidth: CGFloat { list.minimumWidth }
    public var preferredWidth: CGFloat { list.preferredWidth }
    public var selection: ConversationID? { list.selectedID.map { ConversationID($0) } }

    public func update(_ model: HomeSidebarModel) {
        guard model != self.model else { return }
        self.model = model
        list.show((model.pinned + model.rows).map(Self.entry), pinned: model.pinned.map(\.id.rawValue))
    }

    /// Each pinned tile's and row's frame in window points from the top-left (`debug.home page`).
    public var itemFramesInWindow: [(id: ConversationID, pinned: Bool, frame: NSRect)] {
        list.itemFramesInWindow.map { (ConversationID($0.id), $0.pinned, $0.frame) }
    }

    /// Selects `id` without reporting it (the page already shows it).
    public func select(_ id: ConversationID?) { list.select(id?.rawValue) }

    static func entry(_ item: HomeSidebarItem) -> CmuxSidebarEntry {
        CmuxSidebarEntry(id: item.id.rawValue, title: item.title,
                         people: item.people.map { CmuxSidebarEntry.Person(id: $0.id, name: $0.name, initials: $0.initials) },
                         preview: item.preview, previewSender: nil, lastAt: item.lastAt, unreadCount: item.unreadCount,
                         pinned: item.isPinned)
    }

    @objc func newMessage() { onNewMessage() }

    /// A context-menu item for `menuItems` that runs `handler`.
    public static func menuItem(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        CmuxSidebarMenuItem(title: title, handler: handler)
    }

    /// One or two letters for a teammate's monogram.
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace)
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }

    /// The unread dot uses the app's theme accent (sent bubbles alone are iMessage blue).
    func applyColors() {
        list.unreadColor = performWithTheme { Palette.accent }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    public override func layout() {
        super.layout()
        // MessagesLab's search field starts 52 pt down; the button sits centered in that strip.
        let side: CGFloat = 28
        compose.frame = NSRect(x: bounds.width - side - 12, y: bounds.height - 26 - side / 2, width: side, height: side)
    }

}

/// The compose button: a click starts a new message, a right-click offers
/// the other ways to start (`HomeSidebarView.composeMenu`).
final class HomeComposeButton: NSButton {
    weak var owner: HomeSidebarView?

    override func menu(for event: NSEvent) -> NSMenu? { owner?.composeMenu() }
}
