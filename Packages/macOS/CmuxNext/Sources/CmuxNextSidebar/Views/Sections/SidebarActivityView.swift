public import AppKit
import CmuxNextDesign

/// The Activity view (meeting 2026-10-08, AV; `sidebar.activityView`): in
/// place of the sidebar's sections, Priority (chats that need the person,
/// with a blue dot) and then every chat by day, each a title over a one-line
/// preview of its latest message. Virtualized: only visible rows exist.
public final class SidebarActivityView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    static var priorityTitle: String { String(localized: "sidebar.activity.priority", defaultValue: "Priority", bundle: .module) }

    static func title(_ bucket: SidebarActivityBucket) -> String {
        switch bucket {
        case .today: String(localized: "sidebar.activity.today", defaultValue: "Today", bundle: .module)
        case .yesterday: String(localized: "sidebar.activity.yesterday", defaultValue: "Yesterday", bundle: .module)
        case .thisWeek: String(localized: "sidebar.activity.thisWeek", defaultValue: "This week", bundle: .module)
        case .older: String(localized: "sidebar.activity.older", defaultValue: "Older", bundle: .module)
        }
    }

    /// What the dot means, for VoiceOver.
    static func label(_ attention: SidebarActivityAttention) -> String {
        switch attention {
        case .needsInput: String(localized: "sidebar.activity.needsInput", defaultValue: "Needs input", bundle: .module)
        case .failed: String(localized: "sidebar.activity.failed", defaultValue: "Failed", bundle: .module)
        case .unread: Strings.unreadDot
        }
    }

    enum Item: Equatable {
        case header(String)
        case chat(SidebarActivityChat)
        case message(String)
    }

    /// Opens a chat by id (the chat index key).
    public var onOpen: ((String) -> Void)?
    /// The right-click menu of a row or the empty space: the sidebar's background menu.
    var contextMenuProvider: ((SidebarContextTarget) -> NSMenu?)? {
        get { overrideMenuProvider ?? (superview as? SidebarView)?.contextMenuProvider }
        set { overrideMenuProvider = newValue }
    }
    private var overrideMenuProvider: ((SidebarContextTarget) -> NSMenu?)?
    private(set) var items: [Item] = []
    private let table = SidebarActivityTable()
    private let scroll = NSScrollView()

    public override init(frame: NSRect = .zero) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("activity"))
        column.isEditable = false
        table.addTableColumn(column)
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .none
        scroll.drawsBackground = false
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        SystemScrollers.follow(scroll)
        addSubview(scroll)
        setAccessibilityElement(false)
        isHidden = true
        table.menuProvider = { [weak self] in self?.contextMenuProvider?(.background) }
    }

    /// `sidebar`'s Activity view, added on first use; the App feeds it.
    public static func of(_ sidebar: SidebarView) -> SidebarActivityView {
        if let view = sidebar.subviews.lazy.compactMap({ $0 as? SidebarActivityView }).first { return view }
        let view = SidebarActivityView()
        sidebar.addSubview(view)
        return view
    }

    /// Shows the view between `top` and `bottom` of `sidebar` while
    /// `sidebar.activityView` is on, in place of the band above, the workspace
    /// list and the band below; the titlebar row, cards, spaces dots and the
    /// pinned footer section (Settings and account) stay. Off restores them.
    /// Runs after the bands are laid out and before the footer is placed.
    static func place(in sidebar: SidebarView, top: CGFloat, bottom: CGFloat) {
        of(sidebar).place(in: sidebar, top: top, bottom: bottom)
    }

    private func place(in sidebar: SidebarView, top: CGFloat, bottom: CGFloat) {
        let on = DesignSettings.shared.sidebarSections.activityView
        isHidden = !on
        for view in [sidebar.aboveFade, sidebar.edgeFade] { view.isHidden = on }
        guard on else { return }
        // The band line belongs to the sections; the band below takes no
        // height (Back still decides whether it shows), so the footer and
        // cards sit on the pinned footer section.
        sidebar.aboveLine.isHidden = true
        sidebar.belowFade.frame = NSRect(x: 0, y: sidebar.footerRegion.frame.minY, width: sidebar.bounds.width, height: 0)
        frame = NSRect(x: 0, y: top, width: sidebar.bounds.width, height: max(0, bottom - top))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }

    /// Shows the latest chats; `ready` false (the index is still loading)
    /// shows nothing rather than a premature "No chats yet."
    public func update(_ chats: [SidebarActivityChat], ready: Bool, now: Date = Date(), calendar: Calendar = .current) {
        let projection = SidebarActivityProjection(chats: chats, now: now, calendar: calendar)
        var next: [Item] = []
        if !projection.priority.isEmpty {
            next.append(.header(Self.priorityTitle))
            next += projection.priority.map(Item.chat)
        }
        for group in projection.groups {
            next.append(.header(Self.title(group.bucket)))
            next += group.chats.map(Item.chat)
        }
        if next.isEmpty, ready { next = [.message(SidebarChatsView.emptyMessage)] }
        guard next != items else { return }
        items = next
        table.reloadData()
    }

    /// The chats shown, in order (Priority ones appear twice).
    var shownChatIDs: [String] { items.compactMap { if case .chat(let chat) = $0 { chat.id } else { nil } } }

    public override func layout() {
        super.layout()
        scroll.frame = bounds
    }

    /// A chat row: a title line, plus a preview line when there is one.
    static var chatRowHeight: CGFloat { Metrics.sidebarRowHeight + SidebarActivityRowView.previewHeight }

    public func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard items.indices.contains(row), case .chat(let chat) = items[row], chat.preview != nil else { return Metrics.sidebarRowHeight }
        return Self.chatRowHeight
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        switch items[row] {
        case .header(let title):
            return headerView(tableView, title, isHeader: true)
        case .message(let message):
            return headerView(tableView, message, isHeader: false)
        case .chat(let chat):
            let identifier = NSUserInterfaceItemIdentifier("activity-chat")
            let view = (tableView.makeView(withIdentifier: identifier, owner: self) as? SidebarActivityRowView) ?? SidebarActivityRowView()
            view.identifier = identifier
            view.configure(chat)
            view.onPress = { [weak self] in self?.onOpen?(chat.id) }
            view.contextMenu = { [weak self] in self?.contextMenuProvider?(.background) }
            return view
        }
    }

    private func headerView(_ tableView: NSTableView, _ text: String, isHeader: Bool) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier("activity-header")
        let view = (tableView.makeView(withIdentifier: identifier, owner: self) as? SidebarActivityHeaderView) ?? SidebarActivityHeaderView()
        view.identifier = identifier
        view.configure(text, isHeader: isHeader)
        return view
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

/// The table's right-click menu comes from the sidebar, never AppKit's default.
final class SidebarActivityTable: NSTableView {
    var menuProvider: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}
