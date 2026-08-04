import AppKit
import CmuxFoundation

func titlebarShortcutHintShouldShow(
    shortcut: StoredShortcut,
    alwaysShowShortcutHints: Bool,
    modifierPressed: Bool
) -> Bool {
    !shortcut.isUnbound && (alwaysShowShortcutHints || (shortcut.command && modifierPressed))
}

/// Shared native chrome values used by the AppKit titlebar and sidebar controls.
enum HeaderChromeIconStyle {
    static let opacity = 0.86
    static let hoveredOpacity = 0.96
    static let pressedOpacity = 1.0
    static let disabledOpacity = 0.34
    static let weight: NSFont.Weight = .regular
    static let foregroundColor = NSColor.secondaryLabelColor
    static let sidebarGlyphStrokeWidth: CGFloat = 1

    static func iconFrameSize(forIconSize iconSize: CGFloat) -> CGFloat {
        HeaderChromeControlMetrics.iconFrameSize(forIconSize: iconSize)
    }

    static func foregroundOpacity(
        isHovering: Bool,
        isPressed: Bool,
        isEnabled: Bool = true
    ) -> Double {
        guard isEnabled else { return disabledOpacity }
        if isPressed { return pressedOpacity }
        if isHovering { return hoveredOpacity }
        return opacity
    }

    static func backgroundOpacity(
        hoverBackground: Bool,
        isHovering: Bool,
        isPressed: Bool,
        isEnabled: Bool = true
    ) -> Double {
        guard isEnabled else { return 0 }
        if isPressed { return 0.14 }
        if isHovering { return hoverBackground ? 0.09 : 0.07 }
        return 0
    }

    static func borderOpacity(
        buttonBackground: Bool,
        isHovering: Bool,
        isPressed: Bool,
        isEnabled: Bool = true
    ) -> Double {
        guard isEnabled else { return buttonBackground ? 0.04 : 0 }
        if isPressed { return 0.11 }
        if isHovering { return 0.07 }
        return buttonBackground ? 0.05 : 0
    }
}

enum RightSidebarChromeControlStyle {
    static let modeIconSize: CGFloat = 11
    static let secondaryIconSize: CGFloat = 10
    static let labelSize: CGFloat = 11
    static let iconWeight = HeaderChromeIconStyle.weight
    static let labelWeight = HeaderChromeIconStyle.weight
    static let foregroundColor = HeaderChromeIconStyle.foregroundColor

    static func foregroundOpacity(
        isSelected: Bool,
        isHovered: Bool,
        isEnabled: Bool = true
    ) -> Double {
        guard isEnabled else { return HeaderChromeIconStyle.disabledOpacity }
        if isSelected { return HeaderChromeIconStyle.pressedOpacity }
        return HeaderChromeIconStyle.foregroundOpacity(
            isHovering: isHovered,
            isPressed: false,
            isEnabled: isEnabled
        )
    }
}
