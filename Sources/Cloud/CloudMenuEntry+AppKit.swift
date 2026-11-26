import AppKit
import CmuxCloud
import CmuxFoundation

/// AppKit rendering of ``CloudMenuEntry`` for the status item and the Cloud
/// sidebar's context menu. Items carry their closures, so a rebuilt menu never
/// holds a stale target.
@MainActor
enum CloudMenuAppKitRenderer {
    static func items(_ entries: [CloudMenuEntry]) -> [NSMenuItem] {
        entries.map(item)
    }

    static func item(_ entry: CloudMenuEntry) -> NSMenuItem {
        switch entry {
        case .action(let action):
            let item = CloudTreeMenuItem(title: action.title, action: action.perform)
            item.isEnabled = action.isEnabled
            item.state = action.isChecked ? .on : .off
            if let shortcut = action.shortcut {
                apply(KeyboardShortcutSettings.menuShortcut(for: shortcut), to: item)
            }
            item.identifier = NSUserInterfaceItemIdentifier(action.id)
            return item
        case .header(let id, let title):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.identifier = NSUserInterfaceItemIdentifier(id)
            return item
        case .separator(let id):
            let item = NSMenuItem.separator()
            item.identifier = NSUserInterfaceItemIdentifier(id)
            return item
        case .submenu(let submenu):
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(submenu.id)
            if let detail = submenu.detail {
                item.attributedTitle = attributedTitle(submenu.title, detail: detail)
            }
            if let tone = submenu.tone {
                item.image = statusDot(tone)
            }
            let menu = NSMenu(title: submenu.title)
            menu.autoenablesItems = false
            for child in items(submenu.children) { menu.addItem(child) }
            item.submenu = menu
            return item
        }
    }

    /// "noble-wren   Ready": the name at menu weight, the status dimmed.
    static func attributedTitle(_ title: String, detail: String) -> NSAttributedString {
        let font = GlobalFontMagnification.menuFont(ofSize: NSFont.systemFontSize)
        let result = NSMutableAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        result.append(NSAttributedString(string: "  " + detail, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        return result
    }

    /// A small filled circle in the machine's health color. Not a template, so
    /// the color survives menu highlighting.
    static func statusDot(_ tone: CloudMenuTone) -> NSImage {
        let color: NSColor = switch tone {
        case .ready: .systemGreen
        case .pending: .systemYellow
        case .attention: .systemRed
        case .locked: .systemGray
        }
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = switch tone {
        case .ready: String(localized: "machines.activity.ready", defaultValue: "Ready")
        case .pending: String(localized: "machines.activity.pending", defaultValue: "Starting")
        case .attention: String(localized: "cloudMenu.tone.attention", defaultValue: "Needs attention")
        case .locked: String(localized: "cloudMenu.machine.locked", defaultValue: "Locked")
        }
        return image
    }

    private static func apply(_ shortcut: StoredShortcut, to item: NSMenuItem) {
        guard let keyEquivalent = shortcut.menuItemKeyEquivalent else { return }
        item.keyEquivalent = keyEquivalent
        item.keyEquivalentModifierMask = shortcut.modifierFlags
    }
}
