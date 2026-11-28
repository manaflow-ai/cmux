import AppKit
import CmuxNextHistory

/// The rows' action target: a row's tag is its trail index.
final class TitlebarHistoryMenuTarget: NSObject {
    let choose: (Int) -> Void
    init(choose: @escaping (Int) -> Void) { self.choose = choose }
    @objc func pick(_ item: NSMenuItem) { choose(item.tag) }
}

/// The right-click / long-press list of a Back or Forward button (R69):
/// each in-scope entry by title (and workspace); choosing one runs
/// `history.goTo {index}`.
enum TitlebarHistoryMenu {
    static func make(_ items: [LocationTrailListItem], choose: @escaping (Int) -> Void) -> NSMenu {
        let menu = NSMenu()
        let target = TitlebarHistoryMenuTarget(choose: choose)
        for item in items {
            let location = item.entry.location
            let title = location.workspaceTitle.map { "\(location.title) — \($0)" } ?? location.title
            let row = NSMenuItem(title: title, action: #selector(TitlebarHistoryMenuTarget.pick(_:)), keyEquivalent: "")
            row.tag = item.index
            row.target = target
            row.representedObject = target  // NSMenuItem holds its target weakly; the row keeps it alive.
            menu.addItem(row)
        }
        return menu
    }
}
