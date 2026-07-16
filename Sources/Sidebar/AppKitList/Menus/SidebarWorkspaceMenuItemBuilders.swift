import AppKit
import CmuxFoundation
import Foundation

/// `NSMenuItem` that strongly retains a closure and invokes it on selection.
///
/// The sidebar's AppKit context menus are built from snapshot values plus
/// closure action bundles (`SidebarWorkspaceRowActions`,
/// `SidebarWorkspaceGroupHeaderActions`), so items cannot use the responder
/// chain. The item is its own target; the menu retains the item and the item
/// retains the handler for the menu's lifetime.
final class SidebarWorkspaceMenuClosureItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invokeHandler), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("SidebarWorkspaceMenuClosureItem does not support NSCoder")
    }

    @objc private func invokeHandler() {
        handler()
    }
}

/// Shared construction helpers for the sidebar's AppKit context menus.
///
/// Menus are built fresh on every open (the table controller calls the
/// factories per presentation), so nothing here caches state.
@MainActor
enum SidebarWorkspaceMenuItemBuilders {
    /// A menu with `autoenablesItems` off so `isEnabled` mirrors the SwiftUI
    /// `.disabled(...)` conditions exactly.
    static func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        return menu
    }

    static func actionItem(
        title: String,
        enabled: Bool = true,
        state: NSControl.StateValue = .off,
        image: NSImage? = nil,
        shortcut: StoredShortcut? = nil,
        handler: @escaping () -> Void
    ) -> NSMenuItem {
        let item = SidebarWorkspaceMenuClosureItem(title: title, handler: handler)
        item.isEnabled = enabled
        item.state = state
        item.image = image
        if let shortcut,
           let keyEquivalent = shortcut.menuItemKeyEquivalent {
            item.keyEquivalent = keyEquivalent
            item.keyEquivalentModifierMask = shortcut.modifierFlags
        }
        return item
    }

    /// Mirrors SwiftUI's destructive role rendering (red title text).
    static func destructiveActionItem(
        title: String,
        handler: @escaping () -> Void
    ) -> NSMenuItem {
        let item = SidebarWorkspaceMenuClosureItem(title: title, handler: handler)
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.systemRed,
            ]
        )
        return item
    }

    /// Mirrors SwiftUI's `Button(title) {}.disabled(true)` placeholder rows.
    static func disabledItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    static func submenuItem(
        title: String,
        enabled: Bool = true,
        submenu: NSMenu
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = enabled
        item.submenu = submenu
        return item
    }

    static func systemSymbolImage(_ systemName: String) -> NSImage? {
        NSImage(systemSymbolName: systemName, accessibilityDescription: nil)
    }

    /// AppKit-side port of `TabItemView.tabColorSwatchColor(for:)`:
    /// `WorkspaceTabColorSettings.displayNSColor(hex:colorScheme:forceBright:)
    /// ?? NSColor(hex:) ?? .gray`, with the SwiftUI `colorScheme` environment
    /// replaced by the app's effective appearance.
    static func swatchColor(hex: String, forceBright: Bool) -> NSColor {
        guard let normalized = WorkspaceTabColorSettings.normalizedHex(hex),
              let baseColor = NSColor(hex: normalized) else {
            return NSColor(hex: hex) ?? .gray
        }
        let isDarkAppearance =
            NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if forceBright || isDarkAppearance {
            return brightenedForDarkAppearance(baseColor)
        }
        return baseColor
    }

    /// Verbatim duplicate of the private
    /// `WorkspaceTabColorSettings.brightenedForDarkAppearance(_:)`
    /// (Sources/WorkspaceTabColorSettings.swift). Duplicated because the
    /// original is `private` and its public callers take a SwiftUI
    /// `ColorScheme`, which this AppKit-only file cannot import. Keep the two
    /// in sync.
    private static func brightenedForDarkAppearance(_ color: NSColor) -> NSColor {
        let rgbColor = color.usingColorSpace(.sRGB) ?? color
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgbColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let boostedBrightness = min(1, max(brightness, 0.62) + ((1 - brightness) * 0.28))
        // Preserve neutral grays when brightening to avoid introducing hue shifts.
        let boostedSaturation: CGFloat
        if saturation <= 0.08 {
            boostedSaturation = saturation
        } else {
            boostedSaturation = min(1, saturation + ((1 - saturation) * 0.12))
        }

        return NSColor(
            hue: hue,
            saturation: boostedSaturation,
            brightness: boostedBrightness,
            alpha: alpha
        )
    }
}
