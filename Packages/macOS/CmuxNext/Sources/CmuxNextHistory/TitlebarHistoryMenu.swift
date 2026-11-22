public import AppKit
public import CmuxNextDesign

/// The trail rows' action target: a row's tag is its trail index.
final class TitlebarHistoryMenuTarget: NSObject {
    let choose: (Int) -> Void
    init(choose: @escaping (Int) -> Void) {
        self.choose = choose
    }
    @objc func pick(_ item: NSMenuItem) { choose(item.tag) }
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
    /// Inline, each row led by its kind's glyph at the menu's text size. The row height does not change, but
    /// NSMenu gives every row an image column, so the list is one glyph column wider than today's.
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

    /// The longest closed row, in characters, however wide the list already is.
    public static let closedTitleLength = 60

    /// The width closed rows may use when the rows above them are narrower: room for a title and
    /// some of its address, so a short history does not squeeze them to a few letters.
    public static let closedMinWidth: CGFloat = 200

    /// `showAll` is the registry's `history.show` row (it runs the registered action, as the
    /// palette does), retitled Show Full History; nil: no footer. `closed` nil leaves the Recently
    /// Closed section out. `reopenRow(id, title)` is the registry's `history.reopen {id}` row for one
    /// closed item, so the row runs the action the palette, Cmd-Shift-T and the CLI run (nil: no row).
    public static func make(_ sections: [LocationTrailMenuSection], closed: TitlebarHistoryClosedSection? = nil,
                            style: TitlebarHistoryMenuStyle = .inline,
                            choose: @escaping (Int) -> Void,
                            reopenRow: (_ id: String, _ title: String) -> NSMenuItem? = { _, _ in nil },
                            showAll: NSMenuItem?) -> NSMenu {
        let menu = NSMenu()
        let target = TitlebarHistoryMenuTarget(choose: choose)
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
            // NSMenu is as wide as its widest title, so closed rows fit the width the list already has
            // (Leo 2026-11-06: "don't increase any size ... don't baloon it").
            let others = menu.items.map(\.title) + [HistoryStrings.menuRecentlyClosed, showAll == nil ? "" : HistoryStrings.menuShowAll]
            let width = max(closedMinWidth, others.map(titleWidth).max() ?? 0)
            let rows = closedRows(closed, icons: style == .inlineIcons, width: width, reopenRow: reopenRow)
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
    static func closedRows(_ closed: TitlebarHistoryClosedSection, icons: Bool, width: CGFloat,
                           reopenRow: (String, String) -> NSMenuItem?) -> [NSMenuItem] {
        switch closed {
        // The notes are our own short copy, shown whole: cut, they would say nothing. Their width is the
        // string's, never a person's data.
        case .empty: return [note(HistoryStrings.menuNothingClosed)]
        case .unavailable: return [note(HistoryStrings.menuClosedUnavailable)]
        case .rows(let rows):
            return rows.prefix(closedLimit).compactMap { closedRow in
                guard let row = reopenRow(closedRow.id, closedTitle(closedRow, fitting: width)) else { return nil }
                if icons {
                    row.image = NSImage(systemSymbolName: symbol(closedRow.kind), accessibilityDescription: nil)?
                        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: TypeScale.body, weight: .regular))
                }
                row.identifier = NSUserInterfaceItemIdentifier(closedRow.id)
                return row
            }
        }
    }

    /// The longest ``closedTitle(_:length:)`` no wider than `width` at the menu font (a row
    /// image, when any, indents every row alike, so titles compare as they are).
    static func closedTitle(_ row: TitlebarHistoryClosedRow, fitting width: CGFloat) -> String {
        fitting(width) { closedTitle(row, length: $0) }
    }

    /// The longest of `title(1...closedTitleLength)` no wider than `width`.
    static func fitting(_ width: CGFloat, _ title: (Int) -> String) -> String {
        var low = 1, high = closedTitleLength
        while low < high {
            let length = (low + high + 1) / 2
            if titleWidth(title(length)) <= width { low = length } else { high = length - 1 }
        }
        return title(low)
    }

    static func titleWidth(_ title: String) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width)
    }

    /// "title — detail" in at most `length` characters: the title cut at its end, the detail (an
    /// address or a path, whose ends say most) in its middle, and left out when no room is left.
    static func closedTitle(_ row: TitlebarHistoryClosedRow, length: Int = closedTitleLength) -> String {
        let title = clip(row.title, to: length, middle: false)
        let room = length - title.count - 3
        guard let detail = row.detail, !detail.isEmpty, room >= 8 else { return title }
        return "\(title) — \(clip(detail, to: room, middle: true))"
    }

    static func clip(_ text: String, to length: Int, middle: Bool) -> String {
        guard text.count > length else { return text }
        guard length > 1 else { return "…" }
        guard middle else { return String(text.prefix(length - 1)) + "…" }
        let head = (length - 1) / 2
        return String(text.prefix(head)) + "…" + String(text.suffix(length - 1 - head))
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
        case .conversationTab: "bubble.left"
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
