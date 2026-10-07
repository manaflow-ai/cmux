public import AppKit
public import CmuxHomeCore
import MessagesLabSidebar

/// The Home page's left column: MessagesLab's conversation list
/// (`CmuxSidebarView`, vendored byte-identical) drawing a `HomeSidebarModel`
/// with no background of its own: the window's material or background image
/// shows through, as behind the transcript. It owns no data: the page gives
/// it the model after every change and handles the choices.
public final class HomeSidebarView: NSView {
    public var onSelect: (ConversationID) -> Void = { _ in }
    public var onSetPinned: (Bool, ConversationID) -> Void = { _, _ in }
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

    /// Selects `id` without reporting it (the page already shows it).
    public func select(_ id: ConversationID?) { list.select(id?.rawValue) }

    static func entry(_ item: HomeSidebarItem) -> CmuxSidebarEntry {
        CmuxSidebarEntry(id: item.id.rawValue, title: item.title,
                         people: item.people.map { CmuxSidebarEntry.Person(id: $0.id, name: $0.name, initials: $0.initials) },
                         preview: item.preview, previewSender: nil, lastAt: item.lastAt, unreadCount: item.unreadCount,
                         pinned: item.isPinned)
    }

    @objc func newMessage() { onNewMessage() }

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
