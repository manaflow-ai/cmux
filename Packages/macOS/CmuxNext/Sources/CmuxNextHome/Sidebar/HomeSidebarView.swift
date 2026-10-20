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
    /// The header band behind its row: a drag on its empty space moves the window, as on
    /// Messages' sidebar toolbar.
    let dragStrip = HomeWindowDragStrip()
    /// The header row (`HomeSidebarHeaderLayout`): search, the Unread toggle, then compose.
    let compose = HomeHeaderButton(symbol: "square.and.pencil", label: HomeConversationStrings.newMessage,
                                   identifier: "cmux.home.sidebar.compose")
    /// All or Unread: one click, the filled glyph while only unread conversations show
    /// (Home offers no other filter, so no menu).
    let unreadToggle = HomeHeaderButton(symbol: "line.3.horizontal.decrease.circle", onSymbol: "line.3.horizontal.decrease.circle.fill",
                                        label: CmuxSidebarView.unreadTitle, identifier: "cmux.home.sidebar.unread")
    /// The search while the field does not fit beside the buttons: a click opens the field over the row.
    let searchButton = HomeHeaderButton(symbol: "magnifyingglass", label: CmuxSidebarView.searchTitle,
                                        identifier: "cmux.home.sidebar.searchButton")
    /// The search field's capsule: a quiet fill and the composer's hairline rim, stepped toward
    /// the text while the field edits (the composer's focus, #22114), never AppKit's blue ring.
    let searchCapsule = HomeSearchCapsule()
    /// The header's frames at the last layout (tests, `debug.home.sidebar_fixture`).
    public private(set) var header = HomeSidebarHeaderLayout(width: 320, searchOpen: false)
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
        installHeader()
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
        // No system blue in the list: a neutral selection in the theme's tint and grey pinned
        // names, as Messages' pinned grid.
        list.neutralSelection = true
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
    /// selection is the theme's translucent selection tint, never the system blue.
    func applyColors() {
        list.unreadColor = performWithTheme { Palette.accent }
        noteLabel.textColor = performWithTheme { Palette.textSecondary }
        requestsButton.contentTintColor = performWithTheme { Palette.textSecondary }
        // The menu ring: the label colour, not the system accent.
        list.selectionColor = .labelColor
        list.neutralSelectionFill = performWithTheme { Palette.selectionFill }
        layer?.backgroundColor = performWithTheme { Palette.legibilityScrim.cgColor }
        for button in [compose, unreadToggle, searchButton] { button.applyTint() }
        applySearchColors()
    }

    // MARK: Header

    /// The search field without AppKit's bezel and focus ring, in its capsule; the buttons; the
    /// row laid out by `HomeSidebarHeaderLayout` on every list layout.
    private func installHeader() {
        let host = list.headerView
        host.addSubview(dragStrip, positioned: .below, relativeTo: nil)
        searchCapsule.wantsLayer = true
        searchCapsule.layer?.cornerCurve = .continuous
        host.addSubview(searchCapsule, positioned: .below, relativeTo: list.searchField)
        let field = list.searchField
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.setAccessibilityIdentifier("cmux.home.sidebar.search")
        field.onEditingChange = { [weak self] _ in self?.searchEditingChanged() }
        // An emptied field (its cancel button) closes a collapsed search that no longer edits.
        field.onTextChange = { [weak self] in self?.list.headerView.needsLayout = true }
        searchCapsule.onClick = { [weak self] in self?.openSearch() }
        compose.target = self
        compose.action = #selector(newMessage)
        compose.contextMenu = { [weak self] in self?.composeMenu() }
        unreadToggle.target = self
        unreadToggle.action = #selector(toggleUnread)
        searchButton.target = self
        searchButton.action = #selector(openSearch)
        // Over the field: a collapsed search's field sits under its icon button.
        for button in [searchButton, unreadToggle, compose] { host.addSubview(button) }
        list.layoutHeader = { [weak self] bounds in self?.layoutHeader(bounds) ?? HomeSidebarHeaderLayout.band }
    }

    /// The search is open while the field edits or holds a query.
    var searchOpen: Bool { list.searchField.isEditing || !list.searchField.stringValue.isEmpty }

    private func layoutHeader(_ bounds: CGRect) -> CGFloat {
        let h = HomeSidebarHeaderLayout(width: bounds.width, searchOpen: searchOpen)
        header = h
        dragStrip.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h.listTop)
        let collapsedClosed = h.searchButton != nil && !h.buttonsCovered
        searchCapsule.frame = h.search
        searchCapsule.isHidden = collapsedClosed
        searchCapsule.layer?.cornerRadius = h.search.height / 2
        // The field inside its capsule, its text centred on the row. Collapsed and closed it waits
        // under the icon button at full height (alpha 0), so ⌘F and type-to-search still reach it.
        let fieldHeight: CGFloat = 22
        if collapsedClosed, let button = h.searchButton {
            list.searchField.frame = CGRect(x: button.minX, y: button.midY - fieldHeight / 2, width: button.width, height: fieldHeight)
            list.searchField.alphaValue = 0
            list.searchField.setAccessibilityElement(false) // the icon button is the search for VoiceOver
        } else {
            list.searchField.frame = CGRect(x: h.search.minX + 4, y: h.search.midY - fieldHeight / 2,
                                            width: max(0, h.search.width - 8), height: fieldHeight)
            list.searchField.alphaValue = 1
            list.searchField.setAccessibilityElement(true)
        }
        searchButton.isHidden = h.searchButton == nil || h.buttonsCovered
        searchButton.frame = h.searchButton ?? .zero
        unreadToggle.frame = h.filter
        compose.frame = h.compose
        unreadToggle.isHidden = h.buttonsCovered
        compose.isHidden = h.buttonsCovered
        return h.listTop
    }

    /// Focus moves into or out of the field: the ring steps, the caret takes the accent, and a
    /// collapsed search opens over the row or closes back to its icon.
    private func searchEditingChanged() {
        applySearchColors()
        list.headerView.needsLayout = true
    }

    /// The capsule's fill and rim, and the field's text, placeholder and caret, in the theme scope:
    /// the composer's tokens (styles.css `--acpmux-composer-bg` 13 % of the text at 72 %, the rim
    /// `--acpmux-composer-edge` 18 %, focused 22 % further toward the text) on one device pixel.
    func applySearchColors() {
        let field = list.searchField
        let editing = field.isEditing
        performWithTheme {
            let text = Palette.textPrimary
            searchCapsule.layer?.backgroundColor = text.withAlphaComponent(0.13 * 0.72).cgColor
            let rim: CGFloat = editing ? 0.18 + (1 - 0.18) * 0.22 : 0.18
            searchCapsule.layer?.borderColor = text.withAlphaComponent(rim).cgColor
            searchCapsule.layer?.borderWidth = 1 / max(1, window?.backingScaleFactor ?? 2)
            field.textColor = text
            field.placeholderAttributedString = NSAttributedString(string: CmuxSidebarView.searchTitle, attributes: [
                .foregroundColor: Palette.textSecondary,
                .font: field.font ?? .systemFont(ofSize: NSFont.systemFontSize),
            ])
            if let editor = field.currentEditor() as? NSTextView {
                editor.insertionPointColor = Palette.accentFill
                editor.selectedTextAttributes = [.backgroundColor: Palette.textSelection]
            }
        }
    }

    @objc func toggleUnread() { unreadOnly.toggle() }

    /// Only unread conversations show (the Unread toggle's state).
    public var unreadOnly: Bool {
        get { list.unreadOnly }
        set {
            list.unreadOnly = newValue
            unreadToggle.isOn = newValue
        }
    }

    #if DEBUG
    /// Screenshots: true gives the search field the keyboard (a collapsed search opens), false
    /// ends the search and takes the keyboard back.
    public func debugSearch(_ open: Bool) {
        if open {
            window?.makeFirstResponder(list.searchField)
        } else {
            list.clearSearch()
            if list.searchField.isEditing { window?.makeFirstResponder(nil) }
        }
        list.headerView.needsLayout = true
    }

    /// Screenshots (`debug.home.sidebar_fixture`), each optional: the list's `width` (clamped as
    /// a divider drag is), selects the `select`-th row (0 first, below the pinned tiles), sets
    /// the Unread toggle, opens or ends the search (`debugSearch`). The answer is a
    /// `JSONSerialization` graph: the list's `width` and the `header` (each frame as [x, y, width,
    /// height], NSNull when not shown, and `buttonsCovered`); nil when `select` names no row, and
    /// nothing changes then.
    public func debugLook(width: Double?, select: Int?, unread: Bool?, search: Bool?) -> [String: Any]? {
        if let select, !model.rows.indices.contains(select) { return nil }
        let split = superview as? HomeSidebarSplitView
        if let width { split?.setWidth(width) }
        if let select {
            onSelect(model.rows[select].id)
            self.select(model.rows[select].id)
        }
        if let unread { unreadOnly = unread }
        if let search { debugSearch(search) }
        (split?.superview ?? self).layoutSubtreeIfNeeded()
        func frame(_ r: CGRect?) -> Any { r.map { [$0.minX, $0.minY, $0.width, $0.height].map(Double.init) } ?? NSNull() }
        let h = header
        return ["width": Double(split?.sidebarWidth ?? bounds.width),
                "header": ["search": frame(h.search), "searchButton": frame(h.searchButton), "filter": frame(h.filter),
                           "compose": frame(h.compose), "buttonsCovered": h.buttonsCovered] as [String: Any]]
    }
    #endif

    /// The collapsed search's icon: the field opens over the row with the keyboard.
    @objc func openSearch() {
        // An edit already under way keeps its caret and selection.
        guard !list.searchField.isEditing else { return }
        window?.makeFirstResponder(list.searchField)
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
        // The note's and the requests button's strips at the bottom; the list ends above them.
        // The header is the list's (`layoutHeader`), in its flipped root view.
        let note: CGFloat = noteLabel.isHidden ? 0 : 30
        let requests: CGFloat = requestsButton.isHidden ? 0 : 30
        list.frame = NSRect(x: 0, y: note + requests, width: bounds.width, height: bounds.height - note - requests)
        noteLabel.frame = NSRect(x: 14, y: 8, width: max(0, bounds.width - 28), height: 16)
        requestsButton.frame = NSRect(x: 10, y: note + 4, width: max(0, bounds.width - 20), height: 22)
    }

}

/// The search field's capsule: a click on its rim, outside the field, still gives the field the keyboard.
final class HomeSearchCapsule: NSView {
    var onClick: () -> Void = {}
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { onClick() }
}

/// Empty header space that is titlebar: it drags the window, and a double-click runs the user's titlebar action.
final class HomeWindowDragStrip: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { WindowTitlebar.handleMouseDown(event, in: window) }
}
