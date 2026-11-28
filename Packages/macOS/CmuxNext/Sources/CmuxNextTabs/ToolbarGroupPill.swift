import AppKit
import CmuxNextDesign

/// The pill a pane's top right buttons sit on in the grouped and glass styles (`appearance.toolbarButtonStyle`,
/// ``PaneToolbarView``): grouped is the hover fill as one solid pill; glass is the theme's glass tint with a hairline
/// rim. Its ends are round at any height. It takes no clicks, so every button under it stays reachable.
final class ToolbarGroupPill: NSView {
    var style: ToolbarButtonStyle = .standard {
        didSet { if style != oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Frame and color changes snap: the pill follows the buttons, which move without animation.
        layer?.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(), "borderColor": NSNull(),
                          "borderWidth": NSNull(), "cornerRadius": NSNull(), "hidden": NSNull()]
        isHidden = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2 // radius-allow: a pill's round ends
    }

    override func updateLayer() {
        guard let layer else { return }
        let look = performWithTheme { Self.look(style) }
        layer.backgroundColor = look.fill?.cgColor
        layer.borderColor = look.rim?.cgColor
        layer.borderWidth = look.rim == nil ? 0 : 1
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The pill's fill and rim for `style`, from the active theme's tokens (run inside `performWithTheme`).
    static func look(_ style: ToolbarButtonStyle) -> (fill: NSColor?, rim: NSColor?) {
        switch style {
        case .standard, .plain: (nil, nil)
        case .grouped: (Palette.hoverFill, nil)
        case .glass: (Palette.glassTint, Palette.separator)
        }
    }
}
