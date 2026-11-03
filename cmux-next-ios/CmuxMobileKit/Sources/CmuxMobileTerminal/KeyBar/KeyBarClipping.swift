import CoreGraphics

/// Which keys of the key row's scroller are really on screen.
///
/// The scroller passes under the pinned keyboard key, joystick and compose
/// key. A key scrolled under them is clipped from view, but its
/// accessibility frame stays where it was: activating "Left Arrow" by its
/// frame landed on ctrl. An activation lands on the frame's center, so a key
/// whose center is outside the row's visible bounds is hidden from
/// accessibility and offered as an action on the row instead. A key cut at
/// an edge but with its center showing stays (tapping its center hits it).
public struct KeyBarClipping: Sendable {
    public init() {}

    /// Whether `key`'s activation point (its center) is inside `visible`,
    /// the scroll view's visible bounds in the same coordinate space.
    public func isActivatable(_ key: CGRect, in visible: CGRect?) -> Bool {
        guard let visible else { return true }
        guard visible.width > 0, key.width > 0 else { return false }
        return key.midX > visible.minX && key.midX < visible.maxX
    }

    /// Whether all of `key` is inside `visible`. At rest the row shows only
    /// whole keys: a key the edge cuts is not drawn (no sliver, R2-4).
    public func isWhole(_ key: CGRect, in visible: CGRect?) -> Bool {
        guard let visible else { return true }
        return key.minX >= visible.minX - 0.5 && key.maxX <= visible.maxX + 0.5
    }
}

/// The key row's leading fade (classic cmux iOS's edge fade): keys dissolve
/// over `width` points as they reach the pinned keys. At rest nothing fades;
/// the edge's alpha falls to 0 as the row scrolls its first `width` points.
public struct KeyRowFade: Sendable {
    public static let width: CGFloat = 24

    public init() {}

    public func leadingEdgeAlpha(scrolled: CGFloat) -> Double {
        Double(1 - min(1, max(0, scrolled / Self.width)))
    }
}

/// What the bottom dock shows (classic cmux iOS's dock): the key row is
/// always there, keyboard up or down; the composer is open by default and can
/// be closed with the compose key; Hide Toolbar takes both away (and the
/// keyboard) until the next terminal tap. The soft keyboard is tracked for the
/// keyboard key's glyph: a hardware keyboard leaves none.
public struct TerminalDockVisibility: Equatable, Sendable {
    /// The soft keyboard as its notifications last described it.
    public enum SoftKeyboard: Equatable, Sendable {
        /// Not on screen (or a hardware keyboard replaced it).
        case none
        /// On screen, docked at the bottom.
        case shown
        /// Going away (it will-hide; the interactive dismissal ended).
        case hiding
    }

    public var chromeHidden = false
    public var composerPresented = true
    public var softKeyboard: SoftKeyboard = .none

    public init(chromeHidden: Bool = false, composerPresented: Bool = true, softKeyboard: SoftKeyboard = .none) {
        self.chromeHidden = chromeHidden
        self.composerPresented = composerPresented
        self.softKeyboard = softKeyboard
    }

    public var showsKeyRow: Bool { !chromeHidden }
    public var showsComposer: Bool { !chromeHidden && composerPresented }

    /// A will-show or will-change-frame notification's end frame height (pt
    /// on screen): a frame under 100 pt is a hardware keyboard's bar or none.
    public mutating func keyboardWillShow(visibleHeight: CGFloat) {
        softKeyboard = visibleHeight >= 100 ? .shown : .none
    }

    public mutating func keyboardWillHide() {
        if softKeyboard == .shown { softKeyboard = .hiding }
    }

    public mutating func keyboardDidHide() {
        softKeyboard = .none
    }
}

/// What a tap on the compose key does (classic cmux iOS's `ComposerDockState`).
/// The key folds three jobs into one control, told apart by the dock:
///
/// - open (and focus) when the composer is closed;
/// - reveal and focus when it is open but hidden (Hide Toolbar) or shown
///   without focus, so a draft is never dismissed by a tap meant to reach it;
/// - close only when it is shown and focused: a real "done composing".
public struct ComposerDockState: Equatable, Sendable {
    public enum Intent: Equatable, Sendable {
        case openComposer
        case revealAndFocusComposer
        case closeComposer
    }

    public var chromeHidden: Bool
    public var composerPresented: Bool
    public var fieldFocused: Bool

    public init(chromeHidden: Bool, composerPresented: Bool, fieldFocused: Bool) {
        self.chromeHidden = chromeHidden
        self.composerPresented = composerPresented
        self.fieldFocused = fieldFocused
    }

    public func intentForComposeKeyTap() -> Intent {
        guard composerPresented else { return .openComposer }
        if chromeHidden || !fieldFocused { return .revealAndFocusComposer }
        return .closeComposer
    }
}

/// The dock's metrics (classic cmux iOS): a 28 pt key row of keys that hug
/// their labels (glyph keys exactly 32 pt) 4 pt apart, 8 pt above the
/// composer; the composer's controls are 40 pt circles beside a field whose
/// one line is 40 pt tall, with a 28 pt send circle inside it; 12 pt side
/// insets. The stack rests 8 pt above the keyboard or the safe area.
public struct TerminalDockMetrics: Sendable {
    public static let keyRowHeight: CGFloat = 28
    public static let keySpacing: CGFloat = 4
    public static let minKeyWidth: CGFloat = 32
    /// Between the key row and the composer.
    public static let keyRowGap: CGFloat = 8
    public static let horizontalInset: CGFloat = 12
    public static let control: CGFloat = 40
    public static let sendDiameter: CGFloat = 28
    public static let fieldCornerRadius: CGFloat = 20
    /// The field container's padding around the text (and the send circle).
    public static let fieldPadding: CGFloat = 6
    /// The text view's own vertical inset inside that padding.
    public static let textInset: CGFloat = 3

    public init() {}

    /// The composer row with one line of text and nothing else: what the
    /// terminal's rows are measured against. Never its current height: its
    /// Jump to bottom row, an attachment strip or a long draft come and go,
    /// and sizing the PTY by them resized it each time (user report
    /// 2026-10-14: an inline TUI such as Codex redraws its whole transcript on
    /// every resize).
    public func restingComposerHeight(lineHeight: CGFloat) -> CGFloat {
        max(Self.control, (lineHeight + 2 * (Self.textInset + Self.fieldPadding)).rounded(.up))
    }

    /// The whole stack at rest (key row, gap, one-line composer), as shown.
    public func restingStackHeight(lineHeight: CGFloat, visibility: TerminalDockVisibility) -> CGFloat {
        var height: CGFloat = 0
        if visibility.showsKeyRow { height += Self.keyRowHeight }
        if visibility.showsComposer {
            height += restingComposerHeight(lineHeight: lineHeight)
            if visibility.showsKeyRow { height += Self.keyRowGap }
        }
        return height
    }
}

/// The key row's zoom keys step the terminal's font size by one point within
/// the sizes Settings offers (classic cmux iOS's zoom out / zoom in).
public struct TerminalFontZoom: Sendable {
    public let sizes: ClosedRange<Int>

    public init(sizes: ClosedRange<Int>) {
        self.sizes = sizes
    }

    public func step(_ size: Int, larger: Bool) -> Int {
        min(max(size + (larger ? 1 : -1), sizes.lowerBound), sizes.upperBound)
    }
}

/// Where the joystick's thumb is drawn while dragged (user note 2026-10-14):
/// it follows the finger past the circle, so the finger does not cover it, up
/// to 48 pt from the center; the direction is still read from the whole vector.
public struct JoystickGeometry: Sendable {
    /// The circle's diameter in the key row (classic cmux iOS's arrow nub).
    public static let circle: CGFloat = TerminalDockMetrics.keyRowHeight
    /// How far the thumb may travel from the center.
    public static let travel: CGFloat = 48

    public init() {}

    public func thumbOffset(for translation: CGSize) -> CGSize {
        let distance = hypot(translation.width, translation.height)
        guard distance > Self.travel else { return translation }
        let scale = Self.travel / distance
        return CGSize(width: translation.width * scale, height: translation.height * scale)
    }
}

/// The joystick's key repeat (Codex QA F5), like a held key on iOS: one
/// arrow when the drag leaves the dead zone (a flick sends exactly one),
/// then, still held, repeats after 400 ms at 10 per second, rising gently
/// with distance to a cap of 18 per second. The old gears reached 33 per
/// second past 24 pt, so a 1.2 s hold in Codex's 8-row menu landed on an
/// arbitrary row.
public struct JoystickRepeat: Sendable {
    public static let deadZone: CGFloat = 8
    public static let initialDelay: Duration = .milliseconds(400)
    public static let slowestRate = 10.0
    public static let fastestRate = 18.0
    /// Where the fastest rate is reached (the thumb's travel cap).
    public static let fastestAt: CGFloat = JoystickGeometry.travel

    public init() {}

    /// Arrows per second while held at `distance` from the center.
    public func rate(distance: CGFloat) -> Double {
        guard distance > Self.deadZone else { return 0 }
        let t = min(1, max(0, Double((distance - 24) / (Self.fastestAt - 24))))
        return Self.slowestRate + (Self.fastestRate - Self.slowestRate) * t
    }

    public func interval(distance: CGFloat) -> Duration {
        let rate = max(Self.slowestRate, rate(distance: distance))
        return .milliseconds(Int((1000 / rate).rounded()))
    }

    /// Arrows sent by a hold of `seconds` at `distance` (first one included).
    public func arrows(holding seconds: Double, at distance: CGFloat) -> Int {
        guard distance > Self.deadZone else { return 0 }
        let repeating = seconds - 0.4
        guard repeating >= 0 else { return 1 }
        return 1 + Int((repeating * rate(distance: distance)).rounded(.down))
    }
}
