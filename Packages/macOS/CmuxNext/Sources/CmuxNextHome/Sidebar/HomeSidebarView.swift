public import AppKit
public import CmuxHomeCore
import CmuxNextDesign
import MessagesLabSidebar

/// The Home page's left column: MessagesLab's conversation list
/// (`CmuxSidebarView`, vendored byte-identical) drawing a `HomeSidebarModel`
/// over one translucent scrim of the window's background
/// (`Palette.legibilityScrim`): the window's material or background image
/// shows through, as behind the transcript, and the labels keep a calmer
/// base over a light image. No vibrancy material (it drew a solid gray
/// panel) and no opaque fill. It owns no data: the page gives it the model
/// after every change and handles the choices.
public final class HomeSidebarView: NSView {
    public var onSelect: (ConversationID) -> Void = { _ in }
    public var onSetPinned: (Bool, ConversationID) -> Void = { _, _ in }
    /// A drag put a conversation at an index of the pinned grid (a new place, or a row pinned
    /// there); call `update` before returning so the tiles land smoothly.
    public var onPlacePinned: (ConversationID, Int) -> Void = { _, _ in }
    /// Mark as Read (the menu offers it while the conversation is unread or marked unread).
    public var onMarkRead: (ConversationID) -> Void = { _ in }
    /// Mark as Unread (the menu offers it while the conversation is read).
    public var onMarkUnread: (ConversationID) -> Void = { _ in }
    /// The host's context-menu items for a conversation (Archive Chief on a Chief).
    public var menuItems: (ConversationID) -> [NSMenuItem] = { _ in [] }
    /// Teammates matching a query that have no DM yet (the list's extra search section).
    public var teammates: (String) -> [HomeContact] = { _ in [] }
    /// A teammate from the search section was chosen: start (or open) the DM.
    public var onStartTeammate: (HomeContact) -> Void = { _ in }
    public var onNewMessage: () -> Void = {}
    /// The compose button's right-click menu (New Chief, Invite), or nil for none.
    public var composeMenu: () -> NSMenu? = { nil }
    /// The Message Requests button was clicked (`showRequests`).
    public var onOpenRequests: () -> Void = {}

    let list = CmuxSidebarView()
    /// The strip above the search field: a drag there moves the window, as
    /// on Messages' sidebar toolbar.
    let dragStrip = HomeWindowDragStrip()
    /// Messages' compose button, in the strip above the search field.
    let compose = HomeComposeButton()
    /// A quiet line under the list (`HomeSidebarModel.note`).
    let noteLabel = ChromeLabel(labelWithString: "")
    /// "Message Requests (2)" under the list while there are requests (DESIGN 2.3); hidden otherwise.
    let requestsButton = NSButton(title: "", target: nil, action: nil)
    public private(set) var model = HomeSidebarModel(rows: [], pins: HomePins(), me: nil)

    public override init(frame: NSRect) {
        HomeReduceMotion.install()
        super.init(frame: frame)
        wantsLayer = true
        list.frame = bounds
        addSubview(list)
        SystemScrollers.follow(list.scrollView)
        addSubview(dragStrip)
        compose.bezelStyle = .accessoryBarAction
        compose.isBordered = false
        // Messages' compose button: square.and.pencil in a round grey button, the same as the filter button.
        compose.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: HomeConversationStrings.newMessage)?
            .withSymbolConfiguration(Self.roundGlyph)
        compose.imagePosition = .imageOnly
        compose.setAccessibilityLabel(HomeConversationStrings.newMessage)
        compose.setAccessibilityIdentifier("cmux.home.sidebar.compose")
        compose.themedToolTip = HomeConversationStrings.newMessage
        compose.target = self
        compose.action = #selector(newMessage)
        compose.owner = self
        addSubview(compose)
        noteLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noteLabel.lineBreakMode = .byTruncatingTail
        noteLabel.isHidden = true
        noteLabel.setAccessibilityIdentifier("cmux.home.sidebar.note")
        addSubview(noteLabel)
        requestsButton.bezelStyle = .accessoryBarAction
        requestsButton.isBordered = false
        requestsButton.alignment = .left
        requestsButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        requestsButton.image = NSImage(systemSymbolName: "tray", accessibilityDescription: nil)
        requestsButton.imagePosition = .imageLeading
        requestsButton.target = self
        requestsButton.action = #selector(openRequests)
        requestsButton.isHidden = true
        requestsButton.setAccessibilityIdentifier("cmux.home.sidebar.requests")
        addSubview(requestsButton)
        // No system blue in the list: a neutral grey selection and grey pinned names, as Messages'
        // pinned grid; the filter button is the compose button's round twin.
        list.neutralSelection = true
        list.roundFilterSide = Self.roundSide
        list.filterButton.wantsLayer = true
        compose.wantsLayer = true
        list.onSelect = { [weak self] id in if let id { self?.onSelect(ConversationID(id)) } }
        list.onSetPinned = { [weak self] on, id in self?.onSetPinned(on, ConversationID(id)) }
        list.onPlacePinned = { [weak self] id, index in self?.onPlacePinned(ConversationID(id), index) }
        list.onSetRead = { [weak self] read, id in
            if read { self?.onMarkRead(ConversationID(id)) } else { self?.onMarkUnread(ConversationID(id)) }
        }
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
        noteLabel.stringValue = model.note ?? ""
        if noteLabel.isHidden != (model.note == nil) {
            noteLabel.isHidden = model.note == nil
            needsLayout = true
        }
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
                         pinned: item.isPinned, muted: item.isMuted, avatar: item.chiefAvatar.map(avatar), badge: item.backendBadge)
    }

    /// The Chief's avatar as the list draws it: the picture, else its text
    /// as a monogram (one or two letters) or on the grey disc (an emoji).
    /// The disc draws an emoji at half its width, so two would spill past
    /// it: a two-emoji avatar shows its first in the list.
    static func avatar(_ chief: HomeChiefAvatar) -> CmuxSidebarEntry.Avatar {
        switch chief {
        case .picture(let url): return .image(url.absoluteString)
        case .text(let text): return chief.isMonogram ? .monogram(String(text.prefix(2))) : .emoji(String(text.prefix(1)))
        }
    }

    @objc func newMessage() { onNewMessage() }
    @objc func openRequests() { onOpenRequests() }

    /// Shows the Message Requests button for `count` open requests; none hides it.
    public func showRequests(_ count: Int) {
        let title = count > 0 ? HomeConversationStrings.requestsBar(count) : ""
        guard requestsButton.title != title || requestsButton.isHidden != (count == 0) else { return }
        requestsButton.title = title
        requestsButton.setAccessibilityLabel(title)
        if requestsButton.isHidden != (count == 0) {
            requestsButton.isHidden = count == 0
            needsLayout = true
        }
    }

    /// A context-menu item for `menuItems` that runs `handler`.
    public static func menuItem(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        CmuxSidebarMenuItem(title: title, handler: handler)
    }

    /// One or two letters for a teammate's monogram.
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace)
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }

    /// The unread dot uses the app's theme accent (sent bubbles alone are
    /// iMessage blue); the column lays the theme's legibility scrim; the
    /// selection is neutral grey, never the system blue.
    func applyColors() {
        list.unreadColor = performWithTheme { Palette.accent }
        noteLabel.textColor = performWithTheme { Palette.textSecondary }
        requestsButton.contentTintColor = performWithTheme { Palette.textSecondary }
        // The menu ring and an active filter's glyph: the label colour, not the system accent.
        list.selectionColor = .labelColor
        layer?.backgroundColor = performWithTheme { Palette.legibilityScrim.cgColor }
        compose.contentTintColor = .secondaryLabelColor
        for button in [compose, list.filterButton] { applyRoundStyle(button) }
    }

    /// The round buttons' side (the search field's height) and glyph.
    static let roundSide: CGFloat = 30
    static let roundGlyph = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)

    /// A round grey button over the column (Messages' toolbar buttons): a faint label-colour
    /// fill with a hairline rim, so it reads on the window's material and on a light or dark
    /// theme alike.
    func applyRoundStyle(_ button: NSButton) {
        guard let layer = button.layer else { return }
        layer.cornerRadius = Self.roundSide / 2
        layer.masksToBounds = true
        layer.backgroundColor = performWithTheme { NSColor.labelColor.withAlphaComponent(0.08).cgColor }
        layer.borderWidth = 0.5
        layer.borderColor = performWithTheme { NSColor.labelColor.withAlphaComponent(0.12).cgColor }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    /// MessagesLab's search field starts this far down.
    static let stripHeight: CGFloat = 52

    public override func layout() {
        super.layout()
        // The search field starts `stripHeight` down; the button sits centered in that strip.
        let side = Self.roundSide
        dragStrip.frame = NSRect(x: 0, y: bounds.height - Self.stripHeight, width: bounds.width, height: Self.stripHeight)
        // The note's strip at the bottom; the list ends above it.
        // The note's and the requests button's strips at the bottom; the list ends above them.
        let note: CGFloat = noteLabel.isHidden ? 0 : 30
        let requests: CGFloat = requestsButton.isHidden ? 0 : 30
        list.frame = NSRect(x: 0, y: note + requests, width: bounds.width, height: bounds.height - note - requests)
        noteLabel.frame = NSRect(x: 14, y: 8, width: max(0, bounds.width - 28), height: 16)
        requestsButton.frame = NSRect(x: 10, y: note + 4, width: max(0, bounds.width - 20), height: 22)
        // Right-aligned with the filter button under it (the list's search inset, 10 pt).
        compose.frame = NSRect(x: bounds.width - side - 10, y: (bounds.height - 26 - side / 2).rounded(), width: side, height: side)
    }

}

/// The compose button: a click starts a new message, a right-click offers
/// the other ways to start (`HomeSidebarView.composeMenu`).
final class HomeComposeButton: NSButton {
    weak var owner: HomeSidebarView?

    override func menu(for event: NSEvent) -> NSMenu? { owner?.composeMenu() }
}

/// Empty header space that is titlebar: it drags the window, and a double-click runs the user's titlebar action.
final class HomeWindowDragStrip: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { WindowTitlebar.handleMouseDown(event, in: window) }
}
