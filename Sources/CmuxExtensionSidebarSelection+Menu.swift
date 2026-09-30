import AppKit
import CmuxSidebarProviderKit
import Foundation

extension CmuxExtensionSidebarSelection {
    @MainActor
    static func showMenu(anchorView: NSView, event: NSEvent?) {
        // The right-click menu switches between the always-available built-in
        // views (and the hosted extension sidebar when the experimental
        // Extensions beta is enabled, plus any beta custom sidebars), so it is
        // shown regardless of the flag.
        let menu = NSMenu()
        let persistedProviderId = UserDefaults.standard.string(forKey: defaultsKey) ?? defaultProviderId
        let selectedProviderId = descriptor(
            for: effectiveProviderId(persistedProviderId, extensionsEnabled: isEnabled)
        ).id
        for descriptor in descriptors {
            let item = NSMenuItem(
                title: localizedTitle(for: descriptor),
                action: #selector(CmuxExtensionSidebarMenuTarget.selectProvider(_:)),
                keyEquivalent: ""
            )
            item.representedObject = descriptor.id
            item.target = CmuxExtensionSidebarMenuTarget.shared
            item.state = selectedProviderId == descriptor.id ? .on : .off
            item.image = NSImage(systemSymbolName: descriptor.systemImageName, accessibilityDescription: nil)
            menu.addItem(item)
        }
        if let tabManager = AppDelegate.shared?.activeTabManagerForCommands(preferredWindow: anchorView.window) {
            menu.addItem(.separator())
            menu.addItem(groupByMenuItem(for: tabManager))
        }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: anchorView.bounds.maxY + 2),
            in: anchorView
        )
    }

    /// "Group By" submenu for the window the menu opened from. Choosing a mode
    /// while a custom or extension view is showing also switches back to the
    /// workspaces sidebar, the only view that draws grouping.
    @MainActor
    private static func groupByMenuItem(for tabManager: TabManager) -> NSMenuItem {
        let submenu = NSMenu()
        let currentMode = tabManager.sidebarGroupBy.mode
        for mode in SidebarGroupByMode.allCases {
            let item = NSMenuItem(
                title: mode.localizedTitle,
                action: #selector(CmuxExtensionSidebarMenuTarget.selectGroupBy(_:)),
                keyEquivalent: ""
            )
            item.representedObject = CmuxSidebarGroupByMenuChoice(tabManager: tabManager, mode: mode)
            item.target = CmuxExtensionSidebarMenuTarget.shared
            item.state = currentMode == mode ? .on : .off
            submenu.addItem(item)
        }
        let parent = NSMenuItem(
            title: String(localized: "sidebar.groupBy.menu.title", defaultValue: "Group By"),
            action: nil,
            keyEquivalent: ""
        )
        parent.submenu = submenu
        return parent
    }
}

@MainActor
private final class CmuxExtensionSidebarMenuTarget: NSObject {
    static let shared = CmuxExtensionSidebarMenuTarget()

    @objc func selectProvider(_ sender: NSMenuItem) {
        guard let providerId = sender.representedObject as? String else { return }
        CmuxExtensionSidebarSelection.setProviderId(providerId)
    }

    @objc func selectGroupBy(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? CmuxSidebarGroupByMenuChoice else { return }
        choice.tabManager?.selectSidebarGroupBy(choice.mode)
    }
}

/// Menu payload: the target window's manager (weak, so an open menu never
/// keeps a closed window alive) and the chosen mode.
@MainActor
private final class CmuxSidebarGroupByMenuChoice: NSObject {
    weak var tabManager: TabManager?
    let mode: SidebarGroupByMode

    init(tabManager: TabManager, mode: SidebarGroupByMode) {
        self.tabManager = tabManager
        self.mode = mode
        super.init()
    }
}
