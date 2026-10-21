public import AppKit
public import CmuxNextDesign

/// The rows' action target: a row's tag is its trail index.
final class TitlebarHistoryMenuTarget: NSObject {
    let choose: (Int) -> Void
    let showAll: (() -> Void)?
    init(choose: @escaping (Int) -> Void, showAll: (() -> Void)?) {
        self.choose = choose
        self.showAll = showAll
    }
    @objc func pick(_ item: NSMenuItem) { choose(item.tag) }
    @objc func openAll(_ item: NSMenuItem) { showAll?() }
}

/// The right-click / long-press list of a Back or Forward button (R69,
/// history.md 4.2c): each entry by title (and workspace); choosing one runs
/// `history.goTo {index}`. Sections after the first get a header, and Show
/// All History closes the list when there is one.
public struct TitlebarHistoryMenu {
    public init() {}
    /// `showAll` nil: no footer (the `scope` layout, the R69 list as it was).
    public static func make(_ sections: [LocationTrailMenuSection], choose: @escaping (Int) -> Void,
                            showAll: (() -> Void)?) -> NSMenu {
        let menu = NSMenu()
        let target = TitlebarHistoryMenuTarget(choose: choose, showAll: showAll)
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
        if showAll != nil {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let all = NSMenuItem(title: HistoryStrings.menuShowAll, action: #selector(TitlebarHistoryMenuTarget.openAll(_:)), keyEquivalent: "")
            all.target = target
            all.representedObject = target
            menu.addItem(all)
        }
        return menu
    }
}

/// Debug Settings `history.menuLayout` (DEV and NIGHTLY; Release always uses
/// `scopeThenWindow`). The App adds `all` to its tunable catalog.
public nonisolated struct TitlebarHistoryTunables {
    public nonisolated init() {}
    public static let menuLayout = Tunable<LocationTrailMenuLayout>.choice(
        "history.menuLayout", .sidebar, "Back / Forward right-click list",
        help: "What right-clicking (or long-pressing) the titlebar Back or Forward button lists. Applies the next time the list opens.",
        default: .scopeThenWindow, code: "TitlebarHistoryTunables.menuLayout")

    public static var all: [TunableDescriptor] { [menuLayout.descriptor] }
}
