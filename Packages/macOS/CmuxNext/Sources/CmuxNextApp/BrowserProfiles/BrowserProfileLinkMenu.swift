import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextIcons

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
        // Personal browser profiles live in the local daemon, which stores their asset icons.
        let asset = { [weak services] (icon: String?) in
            IconAssetImages.shared.menuImage(icon, owner: services?.machines.local, side: 16)
        }
        for item in profileItems(profiles, asset: asset, run: { [weak services] record in
            services?.registry.perform("browserProfile.openLink", invocation: ActionInvocation(
                target: target,
                arguments: ["browserProfile": .string(record.id), "url": .string(link.absoluteString)]))
        }) {
            submenu.addItem(item)
        }
        let parent = NSMenuItem(title: title.hasSuffix("…") ? String(title.dropLast()) : title, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return [parent, .separator()]
    }

    /// One item per profile, titled by its name. Its icon (an emoji, an SF Symbol name, or a
    /// stored image or SVG that `asset` draws) is the item's image and a profile without one gets
    /// an empty image of the same size, so every name starts in the same column.
    static func profileItems(_ profiles: [BrowserProfileRecord], asset: (String?) -> NSImage? = { _ in nil },
                             run: @escaping @MainActor (BrowserProfileRecord) -> Void) -> [NSMenuItem] {
        profiles.map { record in
            let item = NSMenuItem(title: record.name, action: #selector(ActionMenuClosure.run), keyEquivalent: "")
            let target = ActionMenuClosure { run(record) }
            item.target = target
            item.representedObject = target
            item.image = asset(record.icon) ?? iconImage(record.icon)
            return item
        }
    }

    /// `icon` in a 16 pt square: a symbol as the menu tints it, an emoji centered in its own
    /// colors, or the empty square (also for a stored asset not read yet).
    private static func iconImage(_ icon: String?) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        switch IconValue(wire: icon) {
        case .symbol(let name) where NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil:
            return NSImage.menuSymbol(name) ?? NSImage(size: size)
        case .emoji(let emoji):
            return NSImage(size: size, flipped: false) { rect in
                // 12 pt: a color emoji's glyph runs past its point size.
                let text = NSAttributedString(string: emoji, attributes: [.font: Typography.system(size: 12)])
                let drawn = text.size()
                text.draw(at: NSPoint(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2))
                return true
            }
        default:
            return NSImage(size: size)
        }
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
