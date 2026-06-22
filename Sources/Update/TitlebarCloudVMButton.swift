import SwiftUI
import AppKit

struct TitlebarCloudVMButton: View {
    let config: TitlebarControlsStyleConfig
    let foregroundColor: Color

    var body: some View {
        TitlebarControlButton(
            config: config,
            foregroundColor: foregroundColor,
            accessibilityIdentifier: "titlebarControl.cloudVM",
            accessibilityLabel: String(localized: "titlebar.cloudVM.accessibilityLabel", defaultValue: "Cloud VM"),
            action: {
#if DEBUG
                cmuxDebugLog("titlebar.cloudVM")
#endif
                _ = AppDelegate.shared?.performCloudVMAction(debugSource: "titlebar.cloudVM")
            },
            rightClickAction: { anchorView, event in
                Self.showCloudVMMenu(anchorView: anchorView, event: event)
            }
        ) {
            Image(systemName: "cloud")
                .font(.system(size: config.iconSize, weight: .medium))
                .frame(width: config.buttonSize, height: config.buttonSize)
        }
        .safeHelp(String(localized: "titlebar.cloudVM.tooltip", defaultValue: "Open Cloud VM"))
    }

    @MainActor
    private static func showCloudVMMenu(anchorView: NSView, event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(menuItem(
            title: String(localized: "command.cloudVM.open.title", defaultValue: "Open Cloud VM"),
            action: #selector(CloudVMMenuTarget.open)
        ))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(
            title: String(localized: "command.cloudVM.fork.title", defaultValue: "Fork Current Cloud VM"),
            action: #selector(CloudVMMenuTarget.fork)
        ))
        menu.addItem(menuItem(
            title: String(localized: "command.cloudVM.snapshot.title", defaultValue: "Checkpoint Current Cloud VM"),
            action: #selector(CloudVMMenuTarget.snapshot)
        ))
        menu.addItem(menuItem(
            title: String(localized: "command.cloudVM.restore.title", defaultValue: "Restore Cloud VM From Checkpoint"),
            action: #selector(CloudVMMenuTarget.restore)
        ))
        menu.addItem(menuItem(
            title: String(localized: "command.cloudVM.promoteTemplate.title", defaultValue: "Promote Current VM to Template"),
            action: #selector(CloudVMMenuTarget.promoteTemplate)
        ))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(
            title: String(localized: "command.cloudVM.status.title", defaultValue: "Show Cloud VM Status"),
            action: #selector(CloudVMMenuTarget.status)
        ))
        menu.addItem(menuItem(
            title: String(localized: "command.cloudVM.ports.title", defaultValue: "Show Cloud VM Ports"),
            action: #selector(CloudVMMenuTarget.ports)
        ))
        menu.addItem(menuItem(
            title: String(localized: "command.cloudVM.tools.title", defaultValue: "Inspect Cloud VM Tools"),
            action: #selector(CloudVMMenuTarget.tools)
        ))
        menu.addItem(menuItem(
            title: String(localized: "command.cloudVM.handoff.title", defaultValue: "Show Agent Handoff"),
            action: #selector(CloudVMMenuTarget.handoff)
        ))
        NSMenu.popUpContextMenu(menu, with: event, for: anchorView)
    }

    private static func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = CloudVMMenuTarget.shared
        return item
    }
}

@MainActor
private final class CloudVMMenuTarget: NSObject {
    static let shared = CloudVMMenuTarget()

    @objc func open() {
        _ = AppDelegate.shared?.performCloudVMAction(debugSource: "titlebar.cloudVM.menu.open")
    }

    @objc func fork() {
        _ = AppDelegate.shared?.performCurrentCloudVMCommand(.fork, debugSource: "titlebar.cloudVM.menu.fork")
    }

    @objc func snapshot() {
        _ = AppDelegate.shared?.performCurrentCloudVMCommand(.snapshot, debugSource: "titlebar.cloudVM.menu.snapshot")
    }

    @objc func restore() {
        _ = AppDelegate.shared?.performCloudVMRestoreCommand(debugSource: "titlebar.cloudVM.menu.restore")
    }

    @objc func promoteTemplate() {
        _ = AppDelegate.shared?.performCurrentCloudVMCommand(.promoteTemplate, debugSource: "titlebar.cloudVM.menu.promoteTemplate")
    }

    @objc func status() {
        _ = AppDelegate.shared?.performCurrentCloudVMCommand(.status, debugSource: "titlebar.cloudVM.menu.status")
    }

    @objc func ports() {
        _ = AppDelegate.shared?.performCurrentCloudVMCommand(.ports, debugSource: "titlebar.cloudVM.menu.ports")
    }

    @objc func tools() {
        _ = AppDelegate.shared?.performCurrentCloudVMCommand(.tools, debugSource: "titlebar.cloudVM.menu.tools")
    }

    @objc func handoff() {
        _ = AppDelegate.shared?.performCurrentCloudVMCommand(.handoff, debugSource: "titlebar.cloudVM.menu.handoff")
    }
}
