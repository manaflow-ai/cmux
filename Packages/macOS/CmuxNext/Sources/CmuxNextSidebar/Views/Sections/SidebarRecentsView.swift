public import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The Recents section's rows (`SidebarLayoutDocument.recentsSection`, an
/// app section the App supplies): one row per recent agent chat, with
/// the chat's agent mark, drawn like the pinned sections' items. Once the
/// chats span two projects, a filter row above them names the shown project
/// and its filter button opens a menu of All projects and each project with
/// its badge (Leo, T3 Code ref); there is no search field of its own.
public final class SidebarRecentsView: NSView {
    /// The contribution of the Recents section in the layout.
    public nonisolated static var contribution: String { SidebarLayoutDocument.recentsContribution }
    /// The section's header.
    public static var title: String { String(localized: "sidebar.recents.title", defaultValue: "Recents", bundle: .module) }
    /// A chat with no prompt yet.
    public static var newChatTitle: String { String(localized: "sidebar.recents.newChat", defaultValue: "New chat", bundle: .module) }
    /// The filter menu's first item: no filter.
    public static var allProjectsTitle: String {
        String(localized: "sidebar.recents.allProjects", defaultValue: "All projects", bundle: .module)
    }
    static var filterTitle: String { String(localized: "sidebar.recents.filter", defaultValue: "Filter by project", bundle: .module) }

    public struct Row: Hashable, Sendable {
        public var id: String
        public var title: String
        /// The agent's brand mark (`AgentBrandID`), or nil for the generic chat glyph.
        public var brand: String?

        public init(id: String, title: String, brand: String?) {
            self.id = id
            self.title = title
            self.brand = brand
        }
    }

    /// Opens the chat with this id.
    public var onOpen: ((String) -> Void)?
    /// A project was picked in the filter menu (its folder), or All projects (nil).
    public var onFilter: ((String?) -> Void)?
    public private(set) var rows: [Row] = []
    /// The chats' projects (folders), newest first, and the one shown.
    public private(set) var projects: [String] = []
    public private(set) var selectedProject: String?
    private var views: [String: SidebarItemRowView] = [:]
    let filterBar = NSView()
    let filterBadge = NSImageView()
    let filterLabel = NSTextField(labelWithString: "")
    let filterButton = SidebarIconButton(symbol: "line.3.horizontal.decrease", label: SidebarRecentsView.filterTitle)

    public override var isFlipped: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        filterLabel.font = SidebarStyle.titleFont
        filterLabel.lineBreakMode = .byTruncatingTail
        filterButton.onPress = { [weak self] in self?.showProjectMenu() }
        for view in [filterBadge, filterLabel, filterButton] as [NSView] { filterBar.addSubview(view) }
        filterBar.isHidden = true
        addSubview(filterBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The height of `count` rows, and the filter row when it shows.
    public static func height(rows count: Int, filter: Bool = false) -> CGFloat {
        CGFloat(count + (filter ? 1 : 0)) * Metrics.sidebarRowHeight
    }

    /// The filter row shows once the chats span two projects, or while a filter is on.
    public var showsFilter: Bool { projects.count > 1 || selectedProject != nil }

    public func updateProjects(_ projects: [String], selected: String?) {
        guard projects != self.projects || selected != selectedProject else { return }
        self.projects = projects
        selectedProject = selected
        let badge = selected.map(SidebarProjectBadge.init(path:))
        filterBadge.image = badge?.image()
        filterBadge.isHidden = badge == nil
        filterLabel.stringValue = badge?.name ?? Self.allProjectsTitle
        filterLabel.toolTip = selected
        performWithTheme { filterLabel.textColor = selected == nil ? Palette.textSecondary : Palette.textPrimary }
        needsLayout = true
    }

    /// All projects, then each project with its badge; the shown one is checked.
    func projectMenu() -> NSMenu {
        let menu = NSMenu()
        let all = NSMenuItem(title: Self.allProjectsTitle, action: #selector(pickProject(_:)), keyEquivalent: "")
        all.state = selectedProject == nil ? .on : .off
        menu.addItem(all)
        for project in projects {
            let badge = SidebarProjectBadge(path: project)
            let item = NSMenuItem(title: badge.name, action: #selector(pickProject(_:)), keyEquivalent: "")
            item.representedObject = project
            item.image = badge.image()
            item.toolTip = project
            item.state = project == selectedProject ? .on : .off
            menu.addItem(item)
        }
        for item in menu.items { item.target = self }
        return menu
    }

    private func showProjectMenu() {
        projectMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: filterButton.bounds.maxY + Metrics.space1), in: filterButton)
    }

    @objc private func pickProject(_ item: NSMenuItem) { onFilter?(item.representedObject as? String) }

    public func update(_ rows: [Row]) {
        guard rows != self.rows else { return }
        self.rows = rows
        let ids = Set(rows.map(\.id))
        for (id, view) in views where !ids.contains(id) {
            view.removeFromSuperview()
            views[id] = nil
        }
        for row in rows {
            let view = views[row.id] ?? makeRow(row.id)
            view.configure(SidebarItemInfo(title: row.title, symbol: "bubble.left", icon: .agentChat, brand: row.brand), style: .builtIn)
        }
        needsLayout = true
    }

    private func makeRow(_ id: String) -> SidebarItemRowView {
        let view = SidebarItemRowView()
        view.onPress = { [weak self] in self?.onOpen?(id) }
        views[id] = view
        addSubview(view)
        return view
    }

    public override func layout() {
        super.layout()
        let row = Metrics.sidebarRowHeight
        filterBar.isHidden = !showsFilter
        let top: CGFloat = showsFilter ? row : 0
        if showsFilter { layoutFilterBar(NSRect(x: 0, y: 0, width: bounds.width, height: row)) }
        for (index, item) in rows.enumerated() {
            views[item.id]?.frame = NSRect(x: 0, y: top + CGFloat(index) * row, width: bounds.width, height: row)
        }
    }

    /// The shown project (badge and name, or All projects) leading, the filter button trailing.
    private func layoutFilterBar(_ frame: NSRect) {
        filterBar.frame = frame
        let side = Metrics.sidebarRowHeight - Metrics.space1
        filterButton.frame = NSRect(x: frame.width - Metrics.space2 - side, y: (frame.height - side) / 2, width: side, height: side)
        var x = Metrics.space3
        if let image = filterBadge.image, !filterBadge.isHidden {
            filterBadge.frame = NSRect(x: x, y: (frame.height - image.size.height) / 2, width: image.size.width, height: image.size.height)
            x = filterBadge.frame.maxX + Metrics.space2
        }
        let height = filterLabel.intrinsicContentSize.height
        filterLabel.frame = NSRect(x: x, y: (frame.height - height) / 2, width: max(0, filterButton.frame.minX - Metrics.space2 - x), height: height)
    }
}
