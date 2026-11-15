import AppKit
import CmuxNextDesign
import QuartzCore

/// The "+" after the last tab: the window's standard + (``PlusButtonLook``), which every other + copies. Mouse
/// handling lives in the strip.
final class NewTabButtonView: NSView {
    var showsChevron = false {
        didSet {
            setAccessibilityRole(showsChevron ? .popUpButton : .button)
            look.showsChevron = showsChevron
        }
    }
    var isHovered = false {
        didSet {
            guard oldValue != isHovered else { return }
            applyState(animated: true)
            onHoverChange?(isHovered)
            if isHovered {
                if themedToolTip != nil { themedToolTipShortcut = shortcut?() }
            }
        }
    }
    var isPressed = false { didSet { if oldValue != isPressed { applyState(animated: false) } } }
    /// Held only by this button's menu, including accessibility invocation without hover.
    var isMenuOpen = false { didSet { if oldValue != isMenuOpen { applyState(animated: false) } } }
    var onPress: (() -> Void)?
    /// The trailing controls' shared hover look (``TabTrailingButtons/hoverStyle``).
    var hoverStyle: ChromeHoverStyle {
        get { look.hoverStyle }
        set { look.hoverStyle = newValue }
    }
    /// The + is the leading segment of the split look's `+ ⌄` (``TabTrailingButtons/split``): its fill spans its
    /// frame with the group's leading corners rounded, and shows softly while the ⌄ is hovered.
    var splitSegment: Bool {
        get { look.segment == .leading }
        set { look.segment = newValue ? .leading : .alone }
    }
    /// The ⌄ beside it is under the pointer (the split look's shared hover).
    var siblingHovered = false {
        didSet { if oldValue != siblingHovered { applyState(animated: true) } }
    }
    /// The pointer came onto (true) or left (false) the +.
    var onHoverChange: ((Bool) -> Void)?
    /// The new tab action's shortcut as the person sees it ("⌘T"), read on hover so a rebinding
    /// shows at once; the tooltip draws it after its text.
    var shortcut: (() -> String?)?
    /// VoiceOver moved its focus onto (true) or off (false) the plus.
    var onAccessibilityFocus: ((Bool) -> Void)?

    private(set) lazy var look = PlusButtonLook(host: self)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        _ = look
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(Strings.axNewTab)
        setAccessibilityIdentifier("cmux.tabs.newTab")
        // The plus says what it does and that holding it opens the new tab menu (`TabNewTabHold`).
        themedToolTip = Strings.newTabHoldHint
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
        super.setAccessibilityFocused(accessibilityFocused)
        onAccessibilityFocus?(accessibilityFocused)
    }

    override func layout() {
        super.layout()
        look.layout(in: bounds, scale: window?.backingScaleFactor ?? 2)
    }

    override func updateLayer() {
        look.refresh()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        look.refresh()
    }

    private func applyState(animated: Bool) {
        look.apply(.init(hovering: isHovered, pressed: isPressed, menuOpen: isMenuOpen, siblingHovered: siblingHovered), animated: animated)
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard showsChevron else { return false }
        onPress?()
        return true
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    /// The split control's corner: a tab's (``Metrics/tabCornerRadius``), on a tab's height (``frameHeight``), so the
    /// `+ ⌄` hover reads as a tab, not a pill (Lucas 2026-11-12: "same height and roundness as tabs").
    static var splitCornerRadius: CGFloat { Metrics.tabCornerRadius }

    /// The + button's height in the tab strip: the split look's `+ ⌄` is a tab's height, so its hover fill is a tab's
    /// band; every other look keeps the square button (`side`), centered on the tabs.
    static func frameHeight(split: Bool, side: CGFloat, tabHeight: CGFloat) -> CGFloat { split ? tabHeight : side }
}

/// Flipped container with no event handling of its own.
final class FlippedView: NSView {
    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
