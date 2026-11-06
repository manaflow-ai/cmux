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
    public let time: Date

    public init(id: String, kind: ClosedItem.Kind, title: String, detail: String?, time: Date) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.time = time
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

/// How each row of the Back / Forward list reads (Debug Settings `history.menuStyle`).
public nonisolated enum TitlebarHistoryMenuStyle: String, CaseIterable, Hashable, Sendable, TunableChoice {
    /// One line: "title — workspace", no icon (the list as it was).
    case compact
    /// An icon, the title, and a second line with the workspace and machine.
    case roomy
    /// Roomy, and the second line also says how long ago (the default).
    case roomyTimed

    public var tunableTitle: String {
        switch self {
        case .compact: "Compact: one line per row"
        case .roomy: "Roomy: icon, title, workspace line"
        case .roomyTimed: "Roomy with time: icon, title, workspace and time"
        }
    }
}

/// The right-click / long-press list of a Back or Forward button (R69,
/// history.md 4.2c): the entries that direction walks by title (and workspace); choosing one runs
/// `history.goTo {index}`. Then Recently Closed (each row reopens its own item by id), then
/// Show Full History. Sections after the first get a header.
public struct TitlebarHistoryMenu {
    public init() {}

    /// The widest a roomy list starts at, so titles and their second lines read in full.
    public static let roomyMinimumWidth: CGFloat = 320
    /// Closed rows the list shows; the History page has the rest.
    public static let closedLimit = 8

    /// `showAll` is the registry's `history.show` row (it runs the registered action, as the
    /// palette does), retitled Show Full History; nil: no footer (the `scope` layout, the R69
    /// list as it was). `closed` nil leaves the Recently Closed section out.
    public static func make(_ sections: [LocationTrailMenuSection], closed: TitlebarHistoryClosedSection? = nil,
                            style: TitlebarHistoryMenuStyle = .compact, now: Date = Date(),
                            choose: @escaping (Int) -> Void, reopen: @escaping (String) -> Void = { _ in },
                            showAll: NSMenuItem?) -> NSMenu {
        let menu = NSMenu()
        if style != .compact { menu.minimumWidth = roomyMinimumWidth }
        let target = TitlebarHistoryMenuTarget(choose: choose, reopen: reopen)
        for section in sections where !section.items.isEmpty {
            if let header = HistoryStrings.menuHeader(section.kind) {
                if !menu.items.isEmpty { menu.addItem(.separator()) }
                menu.addItem(.sectionHeader(title: header))
            }
            for item in section.items {
                let location = item.entry.location
                let detail = [location.workspaceTitle, location.machineName].compactMap { $0 }.joined(separator: " · ")
                let row = self.row(title: location.title, detail: detail.isEmpty ? nil : detail, symbol: symbol(location),
                                   time: item.entry.enteredAt, style: style, now: now)
                row.action = #selector(TitlebarHistoryMenuTarget.pick(_:))
                row.tag = item.index
                row.target = target
                row.representedObject = target  // NSMenuItem holds its target weakly; the row keeps it alive.
                menu.addItem(row)
            }
        }
        if let closed {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: HistoryStrings.menuRecentlyClosed))
            switch closed {
            case .rows(let rows):
                for closedRow in rows.prefix(closedLimit) {
                    let row = self.row(title: closedRow.title, detail: closedRow.detail, symbol: symbol(closedRow.kind),
                                       time: closedRow.time, style: style, now: now)
                    row.action = #selector(TitlebarHistoryMenuTarget.pickClosed(_:))
                    row.identifier = NSUserInterfaceItemIdentifier(closedRow.id)
                    row.target = target
                    row.representedObject = target
                    menu.addItem(row)
                }
            case .empty: menu.addItem(note(HistoryStrings.menuNothingClosed))
            case .unavailable: menu.addItem(note(HistoryStrings.menuClosedUnavailable))
            }
        }
        if let all = showAll {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            all.title = HistoryStrings.menuShowAll
            menu.addItem(all)
        }
        return menu
    }

    /// A disabled line that says why a section has no rows.
    static func note(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// One row under `style`. `title` stays the plain title (type-select, VoiceOver); a roomy row
    /// draws the title and its second line from `attributedTitle`.
    static func row(title: String, detail: String?, symbol: String, time: Date, style: TitlebarHistoryMenuStyle,
                    now: Date) -> NSMenuItem {
        guard style != .compact else {
            return NSMenuItem(title: detail.map { "\(title) — \($0)" } ?? title, action: nil, keyEquivalent: "")
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: TypeScale.body, weight: .regular))
        var second = detail.map { [$0] } ?? []
        if style == .roomyTimed { second.append(relative(time, now: now)) }
        let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: TypeScale.body)])
        if !second.isEmpty {
            text.append(NSAttributedString(string: "\n" + second.joined(separator: " · "), attributes: [
                .font: NSFont.menuFont(ofSize: TypeScale.caption),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        item.attributedTitle = text
        return item
    }

    /// "now", "5 min. ago": how long ago a row was entered or closed.
    static func relative(_ time: Date, now: Date) -> String {
        if now.timeIntervalSince(time) < 60 { return HistoryStrings.menuJustNow }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: time, relativeTo: now)
    }

    /// A trail row's glyph: its page, browser, terminal, or chat.
    static func symbol(_ location: HistoryLocation) -> String {
        if location.page != nil { return "doc.text" }
        return switch location.content {
        case .terminal: "terminal"
        case .browser: "globe"
        case .other: "bubble.left"
        }
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
        "history.menuStyle", .sidebar, "Back / Forward right-click rows",
        help: "How each row of the titlebar Back / Forward list reads. Applies the next time the list opens.",
        default: .roomyTimed, code: "TitlebarHistoryTunables.menuStyle")

    public static var all: [TunableDescriptor] { [menuLayout.descriptor, menuStyle.descriptor] }
}
