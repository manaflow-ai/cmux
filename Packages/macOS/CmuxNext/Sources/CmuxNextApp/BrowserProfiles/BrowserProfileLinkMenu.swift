import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDaemon

/// "Open Link in Browser Profile ▸" in a page's context menu: one item per
/// other profile, each running `browserProfile.openLink` (the action every
/// entrypoint shares). Shown when a link was right-clicked and more than
/// one profile exists.
@MainActor
enum BrowserProfileLinkMenu {
    static func items(for link: URL?, pane: PaneModel, services: AppServices) -> [NSMenuItem] {
        let profiles = services.browserProfiles.ordered
        guard let link, profiles.count > 1, let title = services.registry.descriptor(for: "browserProfile.openLink")?.title else { return [] }
        let submenu = NSMenu()
        for record in profiles {
            let item = NSMenuItem(title: record.icon.map { "\($0)  \(record.name)" } ?? record.name, action: nil, keyEquivalent: "")
            let target = ActionMenuClosure { [weak services] in
                services?.registry.perform("browserProfile.openLink", invocation: ActionInvocation(
                    target: ActionTargetRef(kind: .pane, id: pane.id),
                    arguments: ["browserProfile": .string(record.id), "url": .string(link.absoluteString)]))
            }
            item.target = target
            item.action = #selector(ActionMenuClosure.run)
            item.representedObject = target
            submenu.addItem(item)
        }
        let parent = NSMenuItem(title: title.hasSuffix("…") ? String(title.dropLast()) : title, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return [parent, .separator()]
    }
}

/// Keeps a closure alive as a menu item's target.
final class ActionMenuClosure: NSObject {
    private let body: @MainActor () -> Void

    init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
    }

    @MainActor @objc func run() { body() }
}
