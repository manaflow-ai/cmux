import AppKit

/// The tooltip's colors, read in the hovered view's theme scope.
struct TooltipStyle {
    var fill: NSColor
    var border: NSColor
    var ink: NSColor
    var hint: NSColor

    /// The scope's colors, frozen (the panel itself sits in no scope). theme-scoped
    @MainActor static func current() -> TooltipStyle {
        func frozen(_ color: NSColor) -> NSColor { color.usingColorSpace(.sRGB) ?? color }
        return TooltipStyle(fill: frozen(Palette.elevatedBackground), border: frozen(Palette.separator),
                            ink: frozen(Palette.textPrimary), hint: frozen(Palette.textSecondary))
    }
}

/// The one tooltip window: borderless, never key, ignoring the mouse, above page windows and panels
/// like AppKit's own tooltip. Its view is the text, then the shortcut hint, on a small rounded surface.
final class TooltipPanel: NSPanel {
    static let maxWidth: CGFloat = 320
    static let padding = NSSize(width: 8, height: 4)
    static let radius: CGFloat = 5

    let text = NSTextField(wrappingLabelWithString: "")
    let hint = NSTextField(labelWithString: "")
    private let surface = NSView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        level = .popUpMenu
        collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle, .canJoinAllSpaces]
        surface.wantsLayer = true
        surface.layer?.cornerRadius = Self.radius
        surface.layer?.cornerCurve = .continuous
        surface.layer?.borderWidth = 1
        for label in [text, hint] {
            label.font = Typography.caption
            label.isSelectable = false
            label.drawsBackground = false
            label.translatesAutoresizingMaskIntoConstraints = true
            surface.addSubview(label)
        }
        text.maximumNumberOfLines = 0
        hint.alignment = .right
        contentView = surface
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Lays out `text` and `shortcut` in `style` and sizes the window to them.
    func show(text value: String, shortcut: String?, style: TooltipStyle, appearance: NSAppearance) {
        self.appearance = appearance
        surface.layer?.backgroundColor = style.fill.cgColor
        surface.layer?.borderColor = style.border.cgColor
        text.stringValue = value
        text.textColor = style.ink
        hint.stringValue = shortcut ?? ""
        hint.textColor = style.hint
        hint.isHidden = shortcut?.isEmpty ?? true
        let pad = Self.padding
        let hintSize = hint.isHidden ? .zero : hint.fittingSize
        let hintRoom = hint.isHidden ? 0 : hintSize.width + Metrics.space2
        text.preferredMaxLayoutWidth = Self.maxWidth - pad.width * 2 - hintRoom
        let textSize = text.fittingSize
        let width = ceil(textSize.width + hintRoom + pad.width * 2)
        let height = ceil(max(textSize.height, hintSize.height) + pad.height * 2)
        text.frame = NSRect(x: pad.width, y: pad.height, width: ceil(textSize.width), height: ceil(textSize.height))
        hint.frame = NSRect(x: width - pad.width - ceil(hintSize.width), y: height - pad.height - ceil(hintSize.height),
                            width: ceil(hintSize.width), height: ceil(hintSize.height))
        setContentSize(NSSize(width: width, height: height))
        invalidateShadow()
    }
}
