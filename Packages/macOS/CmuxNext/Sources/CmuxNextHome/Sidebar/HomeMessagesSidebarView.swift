public import AppKit
public import CmuxHomeCore
import CmuxNextDesign

/// The Home page's left column in the layout of macOS Messages: a search
/// field, the pinned grid of large avatars (three columns, fewer when
/// narrow), then the conversations newest first. Interim view: it draws a
/// `HomeSidebarModel` and reports choices, so the vendored MessagesLab
/// sidebar replaces it with no data change.
public final class HomeMessagesSidebarView: NSView, NSSearchFieldDelegate {
    /// The narrowest and the starting width of the column (Messages: 220, 300).
    public static let minimumWidth = HomeSidebarWidth.minimum
    public static let defaultWidth = HomeSidebarWidth.standard

    public var onSelect: (ConversationID) -> Void = { _ in }
    public var onQueryChange: (String) -> Void = { _ in }
    public var onNewMessage: () -> Void = {}
    public var onStartPerson: (HomeContact) -> Void = { _ in }
    /// The right-click menu of a conversation, or nil for none.
    public var contextMenu: (ConversationID) -> NSMenu? = { _ in nil }
    /// The right-click menu of the space around the conversations (New
    /// Message, New Chief, Invite), or nil for none.
    public var backgroundMenu: () -> NSMenu? = { nil }

    let search = NSSearchField()
    let compose = NSButton()
    let scroll = NSScrollView()
    let content = HomeSidebarContentView()
    public private(set) var model = HomeSidebarModel(rows: [], pins: HomePins(), me: nil)
    public private(set) var selection: ConversationID?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("cmux.home.sidebar")
        search.placeholderString = HomeConversationStrings.searchPlaceholder
        search.setAccessibilityIdentifier("cmux.home.sidebar.search")
        search.delegate = self
        search.controlSize = .large
        addSubview(search)
        compose.bezelStyle = .accessoryBarAction
        compose.isBordered = false
        compose.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: HomeConversationStrings.newMessage)
        compose.setAccessibilityLabel(HomeConversationStrings.newMessage)
        compose.setAccessibilityIdentifier("cmux.home.sidebar.compose")
        compose.target = self
        compose.action = #selector(newMessage)
        addSubview(compose)
        scroll.documentView = content
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        addSubview(scroll)
        content.owner = self
        content.setAccessibilityLabel(HomeConversationStrings.listTitle)
        wantsLayer = true
        paint()
    }

    private func paint() {
        performWithTheme { layer?.backgroundColor = Palette.sidebarBackground.cgColor }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override var isFlipped: Bool { true }

    /// Shows `model`; keeps the selection when its conversation stays.
    public func update(_ model: HomeSidebarModel) {
        guard model != self.model else { return }
        self.model = model
        content.reload()
    }

    /// Selects `id` without reporting it (the page already shows it).
    public func select(_ id: ConversationID?) {
        selection = id
        content.refreshSelection()
    }

    /// The user chose `id` (click, arrow keys).
    func choose(_ id: ConversationID) {
        selection = id
        content.refreshSelection()
        onSelect(id)
    }

    @objc func newMessage() { onNewMessage() }

    public override func menu(for event: NSEvent) -> NSMenu? { backgroundMenu() }

    public func controlTextDidChange(_ notification: Notification) { onQueryChange(search.stringValue) }

    public override func layout() {
        super.layout()
        let inset = 8 * HomeSidebarMetrics.scale
        let height: CGFloat = 30 * HomeSidebarMetrics.scale
        let button = height
        compose.frame = NSRect(x: bounds.width - inset - button, y: 12, width: button, height: height)
        search.frame = NSRect(x: inset, y: 12, width: max(0, compose.frame.minX - 4 - inset), height: height)
        let top = search.frame.maxY + 10
        scroll.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        content.layoutFor(width: scroll.contentSize.width)
    }
}

/// The scrolling part: tiles, rows and the people a search found. Arrow keys
/// move through the list's order (the grid, then the rows) and stop at the ends.
final class HomeSidebarContentView: NSView {
    weak var owner: HomeMessagesSidebarView?
    private var tiles: [HomePinnedTileView] = []
    private var rows: [HomeSidebarRowView] = []
    private var people: [NSButton] = []
    /// The people buttons' targets (a button holds its target weakly).
    private var personTargets: [HomeClosureTarget] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func reload() {
        guard let owner else { return }
        let model = owner.model
        tiles.forEach { $0.removeFromSuperview() }
        rows.forEach { $0.removeFromSuperview() }
        people.forEach { $0.removeFromSuperview() }
        tiles = model.pinned.map { item in
            let view = HomePinnedTileView()
            view.show(item)
            view.onClick = { [weak owner] in owner?.choose(item.id) }
            addSubview(view)
            return view
        }
        rows = model.rows.enumerated().map { index, item in
            let view = HomeSidebarRowView()
            view.show(item)
            view.showsSeparator = index < model.rows.count - 1
            view.onClick = { [weak owner] in owner?.choose(item.id) }
            addSubview(view)
            return view
        }
        personTargets = []
        people = model.people.map { person in
            let button = NSButton(title: HomeConversationStrings.composeAddPerson(person.name), target: nil, action: nil)
            button.bezelStyle = .inline
            button.setAccessibilityLabel(button.title)
            let action = HomeClosureTarget { [weak owner] in owner?.onStartPerson(person) }
            button.target = action
            button.action = #selector(HomeClosureTarget.fire)
            personTargets.append(action)
            addSubview(button)
            return button
        }
        refreshSelection()
        layoutFor(width: enclosingScrollView?.contentSize.width ?? bounds.width)
    }

    func refreshSelection() {
        let selected = owner?.selection
        for tile in tiles { tile.isSelected = tile.item?.id == selected }
        for row in rows { row.isSelected = row.item?.id == selected }
    }

    /// Frames for `width`: the grid takes as many columns as fit, up to three.
    func layoutFor(width: CGFloat) {
        let m = HomeSidebarMetrics.self
        let columns = HomeSidebarWidth.gridColumns(width: width, tileWidth: m.tileWidth)
        let tileWidth = width / CGFloat(columns)
        for (index, tile) in tiles.enumerated() {
            let x = CGFloat(index % columns) * tileWidth
            let y = CGFloat(index / columns) * m.tileHeight
            tile.frame = NSRect(x: x + 5, y: y, width: tileWidth - 10, height: m.tileHeight)
        }
        var y = ceil(CGFloat(tiles.count) / CGFloat(columns)) * m.tileHeight + (tiles.isEmpty ? 0 : 12)
        for row in rows {
            row.frame = NSRect(x: 6, y: y, width: width - 12, height: m.rowHeight)
            y += m.rowHeight
        }
        for button in people {
            button.frame = NSRect(x: m.rowTextX, y: y + 4, width: width - m.rowTextX - m.trailing, height: 24)
            y += 28
        }
        frame = NSRect(x: 0, y: 0, width: width, height: max(y + 8, enclosingScrollView?.contentSize.height ?? 0))
    }

    override func keyDown(with event: NSEvent) {
        guard let owner else { return super.keyDown(with: event) }
        let offset: Int? = switch event.keyCode {
        case 125, 124: 1 // down, right
        case 126, 123: -1 // up, left
        default: nil
        }
        guard let offset else { return super.keyDown(with: event) }
        if let next = owner.model.neighbor(of: owner.selection, offset: offset) { owner.choose(next) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let id = (tiles.first { $0.frame.contains(point) }?.item ?? rows.first { $0.frame.contains(point) }?.item)?.id
        guard let id else { return owner?.backgroundMenu() }
        return owner?.contextMenu(id)
    }
}

/// A target that runs a closure (the search's people buttons).
final class HomeClosureTarget: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}
