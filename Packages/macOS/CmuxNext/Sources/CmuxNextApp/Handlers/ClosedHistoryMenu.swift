import AppKit
import CmuxNextActions
import CmuxNextDaemon

/// Recently Closed…: the daemons' closed tabs, screens, and workspaces,
/// newest first, as a menu over the active window. Choosing one runs
/// `recentlyClosed` with its id, the same path as
/// `cmux app recently-closed --arg closed=<id>`.
@MainActor
enum ClosedHistoryMenu {
    /// The menu's title for `item`: its name, else a kind placeholder.
    static func title(_ item: ClosedItem) -> String {
        if let name = item.name, !name.isEmpty { return name }
        switch item.kind {
        case .tab: return MiscHandlerStrings.untitledTab
        case .screen: return MiscHandlerStrings.untitledScreen
        case .workspace: return MiscHandlerStrings.untitledWorkspace
        }
    }

    static func symbol(_ item: ClosedItem) -> String {
        switch item.kind {
        case .tab: item.tabs.first?.kind == "browser" ? "globe" : "terminal"
        case .screen: "rectangle.on.rectangle"
        case .workspace: "sidebar.left"
        }
    }

    /// Pops the menu up at the top of `window`'s content; `choose` runs with
    /// the chosen item's id.
    static func popUp(_ entries: [DaemonClosedHistory.Entry], in window: NSWindow, choose: @escaping @MainActor (String) -> Void) {
        let menu = NSMenu()
        let target = Target(choose: choose)
        for entry in entries {
            let item = NSMenuItem(title: title(entry.item), action: #selector(Target.chosen(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: symbol(entry.item), accessibilityDescription: nil)
            item.representedObject = entry.item.id
            item.target = target
            menu.addItem(item)
        }
        guard let view = window.contentView else { return }
        // Menu items hold their target weakly; tracking ends before popUp returns.
        withExtendedLifetime(target) {
            _ = menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.midX, y: view.bounds.maxY - 40), in: view)
        }
    }

    private final class Target: NSObject {
        let choose: @MainActor (String) -> Void

        init(choose: @escaping @MainActor (String) -> Void) {
            self.choose = choose
        }

        @objc func chosen(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String else { return }
            choose(id)
        }
    }
}
