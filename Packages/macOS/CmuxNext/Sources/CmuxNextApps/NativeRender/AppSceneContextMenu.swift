import AppKit
import CmuxNextDesign

/// A node's `menu` prop as an `NSMenu`: entries `{title, destructive?, disabled?, symbol?, children?}`
/// or `{divider: true}`; a pick reports its index path, as the SwiftUI renderer's menu does. The
/// caller keeps this object alive while the menu shows: its items target it weakly.
@MainActor
final class AppSceneContextMenu: NSObject {
    private let pick: ([Int]) -> Void
    private(set) var menu = NSMenu()

    init(items: [AppJSON], pick: @escaping ([Int]) -> Void) {
        self.pick = pick
        super.init()
        menu = build(items, path: [])
    }

    private func build(_ items: [AppJSON], path: [Int]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, item) in items.enumerated() {
            if item["divider"]?.boolValue == true {
                menu.addItem(.separator())
                continue
            }
            let entry = NSMenuItem(title: item["title"]?.stringValue ?? "", action: nil, keyEquivalent: "")
            if let symbol = item["symbol"]?.stringValue { entry.image = NSImage.menuSymbol(symbol) }
            if let children = item["children"]?.arrayValue {
                entry.submenu = build(children, path: path + [index])
            } else {
                entry.target = self
                entry.action = #selector(choose(_:))
                entry.representedObject = path + [index]
                entry.isEnabled = item["disabled"]?.boolValue != true
            }
            menu.addItem(entry)
        }
        return menu
    }

    @objc private func choose(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? [Int] { pick(path) }
    }
}
