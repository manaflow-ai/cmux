import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDaemon

/// "Open Link in Browser Profile ▸" in a page's or a terminal's context
/// menu: one item per profile, each running `browserProfile.openLink` (the
/// action every entrypoint shares) at `target` (the pane or tab the link
/// was in). Shown when a web link was right-clicked and more than one
/// profile exists.
@MainActor
enum BrowserProfileLinkMenu {
    static func items(for link: URL?, target: ActionTargetRef?, services: AppServices) -> [NSMenuItem] {
        let profiles = services.browserProfiles.ordered
        guard let link, link.scheme == "http" || link.scheme == "https", profiles.count > 1, let title = services.registry.descriptor(for: "browserProfile.openLink")?.title else { return [] }
        let submenu = NSMenu()
        for record in profiles {
            let item = NSMenuItem(title: record.icon.map { "\($0)  \(record.name)" } ?? record.name, action: nil, keyEquivalent: "")
            let target = ActionMenuClosure { [weak services] in
                services?.registry.perform("browserProfile.openLink", invocation: ActionInvocation(
                    target: target,
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
