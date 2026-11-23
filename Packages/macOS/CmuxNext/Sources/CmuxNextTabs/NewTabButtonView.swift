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
        // The tab bar's +: a tab's corner, as the tabs and the pane's ⋮ beside it (Lawrence 2026-11-20).
        look.roundsAsTabBarControl = true
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

    /// The split control's corner: a tab pill's (``PlusButtonLook/splitCornerRadius``), as the ⋮ beside it rounds.
    static var splitCornerRadius: CGFloat { PlusButtonLook.splitCornerRadius }

    /// The + button's height in the tab strip, in every look: the pane ⋮'s side (``Metrics/tabBarControlSide``), centered
    /// on the tabs, so the +, its ⌄ and the ⋮ are one size (Lawrence 2026-11-20: "size of plus button must be same as
    /// size of these buttons"). Before, the split look's `+ ⌄` was a tab's height, taller than the ⋮.
    static var frameHeight: CGFloat { Metrics.tabBarControlSide }
}

/// Flipped container with no event handling of its own.
final class FlippedView: NSView {
    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
