import AppKit
import CmuxNextDesign

/// Debug menu > Sidebar Priority (DEV and NIGHTLY): compares the live
/// attention projection with the user's manual sidebar order.
final class SidebarPriorityMenu: NSObject, NSMenuDelegate {
    static let shared = SidebarPriorityMenu()

    private enum Mode: String {
        case setting
        case manual
        case attention
    }

    func makeItem() -> NSMenuItem {
        let item = NSMenuItem(title: Strings.menuSidebarPriority, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: Strings.menuSidebarPriority)
        menu.delegate = self
        add(Strings.menuSidebarPriorityFollowSetting, mode: .setting, to: menu)
        add(Strings.menuSidebarPriorityManual, mode: .manual, to: menu)
        add(Strings.menuSidebarPriorityAttention, mode: .attention, to: menu)
        updateStates(in: menu)
        item.submenu = menu
        return item
    }

    @objc func choose(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = Mode(rawValue: raw) else { return }
        DesignSettings.shared.sidebarPriorityOverride = switch mode {
        case .setting: nil
        case .manual: false
        case .attention: true
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { updateStates(in: menu) }

    private func add(_ title: String, mode: Mode, to menu: NSMenu) {
        let choice = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
        choice.target = self
        choice.representedObject = mode.rawValue
        menu.addItem(choice)
    }

    private func updateStates(in menu: NSMenu) {
        let current: Mode = if let override = DesignSettings.shared.sidebarPriorityOverride {
            override ? .attention : .manual
        } else {
            .setting
        }
        for item in menu.items { item.state = (item.representedObject as? String) == current.rawValue ? .on : .off }
    }
}
