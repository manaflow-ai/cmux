public import AppKit
public import CmuxNextDesign

/// The rows' action target: a trail row's tag is its trail index, a closed row's represented id
/// is its closed item's history id.
final class TitlebarHistoryMenuTarget: NSObject {
    let choose: (Int) -> Void
    let reopen: (String) -> Void
    init(choose: @escaping (Int) -> Void, reopen: @escaping (String) -> Void) {
        self.choose = choose
        self.reopen = reopen
    }
    @objc func pick(_ item: NSMenuItem) { choose(item.tag) }
    @objc func pickClosed(_ item: NSMenuItem) {
        guard let id = item.identifier?.rawValue, !id.isEmpty else { return }
        reopen(id)
    }
}

/// One row of the Recently Closed section: a closed tab, screen or workspace by its history id
/// (`daemon:<item id>`), so choosing it reopens exactly that item, never the newest one.
public nonisolated struct TitlebarHistoryClosedRow: Hashable, Sendable {
    public let id: String
    public let kind: ClosedItem.Kind
    public let title: String
    /// The address, folder or page under the title, and the machine when it is not this Mac.
    public let detail: String?

    public init(id: String, kind: ClosedItem.Kind, title: String, detail: String?) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}

/// What the Recently Closed section shows. The rows come from the mirrored closed history
/// (`DaemonStore.closedItems`), so opening the list waits on nothing.
public nonisolated enum TitlebarHistoryClosedSection: Hashable, Sendable {
    case rows([TitlebarHistoryClosedRow])
    /// Closed history is served and holds nothing yet.
    case empty
    /// No connected machine serves closed history (the daemon is starting or offline).
    case unavailable
}

/// How the Back / Forward list shows Recently Closed (Debug Settings `history.menuStyle`). Every style
/// keeps the list's size (Leo 2026-11-06: "don't increase any size ... after adding a recently closed
/// section, don't shrink it stupidly ... don't baloon it"): rows stay one line at the menu's own
/// font and width, the history sections list exactly what they listed before, and Recently Closed
/// adds at most ``TitlebarHistoryMenu/closedLimit`` rows (or one row, as a submenu).
public nonisolated enum TitlebarHistoryMenuStyle: String, CaseIterable, Hashable, Sendable, TunableChoice {
    /// Recently Closed inline under its header, one line per row (the default).
    case inline
    /// Inline, each row led by its kind's glyph at the menu's text size (the row height does not change).
    case inlineIcons
    /// One "Recently Closed" row that opens the closed items as a submenu: the list grows by one row.
    case submenu

    public var tunableTitle: String {
        switch self {
        case .inline: "Recently Closed inline, one line per row"
        case .inlineIcons: "Recently Closed inline, with kind icons"
        case .submenu: "Recently Closed as a submenu"
        }
    }
}

/// The right-click / long-press list of a Back or Forward button (R69,
/// history.md 4.2c): the entries that direction walks by title (and workspace); choosing one runs
/// `history.goTo {index}`. Then Recently Closed (each row reopens its own item by id), then
/// Show Full History. Sections after the first get a header.
public struct TitlebarHistoryMenu {
    public init() {}

    /// Closed rows the list shows; the History page has the rest. Small, so the history rows above
    /// keep the room they had.
    public static let closedLimit = 5

    /// `showAll` is the registry's `history.show` row (it runs the registered action, as the
    /// palette does), retitled Show Full History; nil: no footer. `closed` nil leaves the Recently
    /// Closed section out.
    public static func make(_ sections: [LocationTrailMenuSection], closed: TitlebarHistoryClosedSection? = nil,
                            style: TitlebarHistoryMenuStyle = .inline,
                            choose: @escaping (Int) -> Void, reopen: @escaping (String) -> Void = { _ in },
                            showAll: NSMenuItem?) -> NSMenu {
        let menu = NSMenu()
        let target = TitlebarHistoryMenuTarget(choose: choose, reopen: reopen)
        for section in sections where !section.items.isEmpty {
            if let header = HistoryStrings.menuHeader(section.kind) {
                if !menu.items.isEmpty { menu.addItem(.separator()) }
                menu.addItem(.sectionHeader(title: header))
            }
            for item in section.items {
                let location = item.entry.location
                let title = location.workspaceTitle.map { "\(location.title) — \($0)" } ?? location.title
                let row = NSMenuItem(title: title, action: #selector(TitlebarHistoryMenuTarget.pick(_:)), keyEquivalent: "")
                row.tag = item.index
                row.target = target
                row.representedObject = target  // NSMenuItem holds its target weakly; the row keeps it alive.
                menu.addItem(row)
            }
        }
        if let closed {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let rows = closedRows(closed, icons: style == .inlineIcons, target: target)
            if style == .submenu {
                let item = NSMenuItem(title: HistoryStrings.menuRecentlyClosed, action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: HistoryStrings.menuRecentlyClosed)
                rows.forEach(submenu.addItem)
                item.submenu = submenu
                menu.addItem(item)
            } else {
                menu.addItem(.sectionHeader(title: HistoryStrings.menuRecentlyClosed))
                rows.forEach(menu.addItem)
            }
        }
        if let all = showAll {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            all.title = HistoryStrings.menuShowAll
            menu.addItem(all)
        }
        return menu
    }

    /// The Recently Closed rows, newest first and at most ``closedLimit``, or the one disabled line
    /// that says why there are none.
    static func closedRows(_ closed: TitlebarHistoryClosedSection, icons: Bool, target: TitlebarHistoryMenuTarget) -> [NSMenuItem] {
        switch closed {
        case .empty: return [note(HistoryStrings.menuNothingClosed)]
        case .unavailable: return [note(HistoryStrings.menuClosedUnavailable)]
        case .rows(let rows):
            return rows.prefix(closedLimit).map { closedRow in
                let title = closedRow.detail.map { "\(closedRow.title) — \($0)" } ?? closedRow.title
                let row = NSMenuItem(title: title, action: #selector(TitlebarHistoryMenuTarget.pickClosed(_:)), keyEquivalent: "")
                if icons {
                    row.image = NSImage(systemSymbolName: symbol(closedRow.kind), accessibilityDescription: nil)?
                        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: TypeScale.body, weight: .regular))
                }
                row.identifier = NSUserInterfaceItemIdentifier(closedRow.id)
                row.target = target
                row.representedObject = target
                return row
            }
        }
    }

    /// A disabled line that says why a section has no rows.
    static func note(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    static func symbol(_ kind: ClosedItem.Kind) -> String {
        switch kind {
        case .terminalTab: "terminal"
        case .browserTab: "globe"
        case .screen: "rectangle.split.2x1"
        case .workspace: "square.stack"
        }
    }
}

/// Debug Settings `history.menuLayout` and `history.menuStyle` (DEV and NIGHTLY; Release always
/// uses the defaults). The App adds `all` to its tunable catalog.
public nonisolated struct TitlebarHistoryTunables {
    public nonisolated init() {}
    public static let menuLayout = Tunable<LocationTrailMenuLayout>.choice(
        "history.menuLayout", .sidebar, "Back / Forward right-click list",
        help: "What right-clicking (or long-pressing) the titlebar Back or Forward button lists. Applies the next time the list opens.",
        default: .scopeThenWindow, code: "TitlebarHistoryTunables.menuLayout")
    public static let menuStyle = Tunable<TitlebarHistoryMenuStyle>.choice(
        "history.menuStyle", .sidebar, "Back / Forward Recently Closed",
        help: "How the titlebar Back / Forward list shows Recently Closed. Applies the next time the list opens.",
        default: .inline, code: "TitlebarHistoryTunables.menuStyle")

    public static var all: [TunableDescriptor] { [menuLayout.descriptor, menuStyle.descriptor] }
}
