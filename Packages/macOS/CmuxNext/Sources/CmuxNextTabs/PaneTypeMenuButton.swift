import AppKit
import CmuxNextDesign

/// The pane strip handles pointer events; accessibility invokes the same menu directly.
/// Keep NSButton's click simulation out of AXPress: a popup is open on press, not on release.
final class PaneTypeMenuButton: NSView {
    private let glyph = TitlebarBandButton(symbol: "chevron.down")
    var onPress: (() -> Void)?
    /// VoiceOver moved its focus onto (true) or off (false) the chooser.
    var onAccessibilityFocus: ((Bool) -> Void)?
    var isHighlighted = false {
        didSet {
            glyph.isHighlighted = isHighlighted
            glyph.hover.state.pressed = isHighlighted
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(glyph)
        glyph.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel(Strings.axNewTab)
        setAccessibilityIdentifier("cmux.tabs.newTabMenu")
        themedToolTip = Strings.axNewTab
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        glyph.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool { accessibilityPerformPress() }

    override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
        super.setAccessibilityFocused(accessibilityFocused)
        onAccessibilityFocus?(accessibilityFocused)
    }
}
