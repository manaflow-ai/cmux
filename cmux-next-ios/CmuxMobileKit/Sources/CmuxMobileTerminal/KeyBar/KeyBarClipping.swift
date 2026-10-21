import CoreGraphics

/// Which keys of the key bar's scrolling middle row are really on screen.
///
/// The middle row scrolls under the pinned esc / ctrl / alt group and the
/// joystick. A key scrolled under them is clipped from view, but its
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

/// The key bar scroller's edge fades (SPEC B2): 12 pt gradient masks, the
/// leading one only once the row is scrolled (at rest the first key starts
/// at a hard edge), the trailing one while more keys wait to the right.
public struct KeyBarScrollEdges: Equatable, Sendable {
    public static let fade: CGFloat = 12
    /// The trailing fade, 12 pt as specified (R2-4). It shows only while the
    /// row moves: at rest the row draws whole keys only, so the last one is
    /// at full brightness.
    public static let trailingFade: CGFloat = 12

    public var offset: CGFloat
    public var contentWidth: CGFloat
    public var visibleWidth: CGFloat

    public init(offset: CGFloat = 0, contentWidth: CGFloat = 0, visibleWidth: CGFloat = 0) {
        self.offset = offset
        self.contentWidth = contentWidth
        self.visibleWidth = visibleWidth
    }

    public var fadesLeading: Bool { offset > 0.5 }
    public var fadesTrailing: Bool { offset + visibleWidth < contentWidth - 0.5 }
}

/// One rule for when the key bar shows (SPEC M4), in mock and live alike:
/// whenever the terminal or its composer has focus, with the soft keyboard
/// or a hardware keyboard (esc, ctrl, ^C and the arrows matter most on a
/// hardware keyboard without them); never at rest.
public struct KeyBarVisibility: Equatable, Sendable {
    /// The soft keyboard as its notifications last described it.
    public enum SoftKeyboard: Equatable, Sendable {
        /// Not on screen (or a hardware keyboard replaced it).
        case none
        /// On screen, docked at the bottom.
        case shown
        /// Going away (it will-hide; the interactive dismissal ended).
        case hiding
    }

    public enum Mode: Equatable, Sendable {
        /// Folded away: the composer sits alone above the toolbar.
        case hidden
        /// 44 pt, clipped to the keyboard's height so it rides the keyboard's
        /// own animation and interactive dismissal.
        case followsKeyboard
        /// 44 pt above the composer's resting line: focus with no soft keyboard.
        case pinned
    }

    public var inputFocused = false
    public var softKeyboard: SoftKeyboard = .none

    public init(inputFocused: Bool = false, softKeyboard: SoftKeyboard = .none) {
        self.inputFocused = inputFocused
        self.softKeyboard = softKeyboard
    }

    public var mode: Mode {
        guard inputFocused else { return .hidden }
        return softKeyboard == .none ? .pinned : .followsKeyboard
    }

    /// A will-show or will-change-frame notification's end frame height (pt
    /// on screen): a frame under 100 pt is a hardware keyboard's bar or none.
    public mutating func keyboardWillShow(visibleHeight: CGFloat) {
        softKeyboard = visibleHeight >= 100 ? .shown : .none
    }

    public mutating func keyboardWillHide() {
        if softKeyboard == .shown { softKeyboard = .hiding }
    }

    /// The keyboard finished hiding; focus that outlives it is typing on a
    /// hardware keyboard.
    public mutating func keyboardDidHide() {
        softKeyboard = .none
    }
}

/// The key bar scroller's geometry (round 5, R3-5): its keys share one width
/// and the scroller is a whole number of them with 6 pt gaps, so a snapped
/// row always shows whole keys, evenly spaced, with nothing left over.
public struct KeyBarLayout: Sendable {
    public static let keyWidth: CGFloat = 44
    public static let spacing: CGFloat = 6

    public init() {}

    /// Keys that fit in `available` points.
    public func visibleKeys(available: CGFloat) -> Int {
        max(1, Int(floor((available + Self.spacing) / (Self.keyWidth + Self.spacing))))
    }

    /// The scroller's width for `available` points: a whole number of keys.
    public func scrollerWidth(available: CGFloat) -> CGFloat {
        guard available > 0 else { return 0 }
        let keys = CGFloat(visibleKeys(available: available))
        return min(available, keys * Self.keyWidth + (keys - 1) * Self.spacing)
    }
}

/// Where the joystick's thumb is drawn while dragged (user note 2026-10-14):
/// it follows the finger past the 32 pt circle, so the finger does not cover
/// it, up to 1.5x the circle (48 pt from the center); the direction is still
/// read from the whole vector.
public struct JoystickGeometry: Sendable {
    /// The circle's diameter in the key bar.
    public static let circle: CGFloat = 32
    /// How far the thumb may travel from the center.
    public static let travel: CGFloat = circle * 1.5

    public init() {}

    public func thumbOffset(for translation: CGSize) -> CGSize {
        let distance = hypot(translation.width, translation.height)
        guard distance > Self.travel else { return translation }
        let scale = Self.travel / distance
        return CGSize(width: translation.width * scale, height: translation.height * scale)
    }
}

/// The composer's metrics (user note 2026-10-14): the + and send circles sit
/// with equal insets to the card's leading/trailing, top and bottom edges.
/// One line of text is exactly as tall as the circles, so the card's 6 pt
/// padding is the inset on every side.
public struct ComposerMetrics: Sendable {
    public static let circle: CGFloat = 36
    public static let padding: CGFloat = 6

    public init() {}

    /// The card's height with one line of text and nothing else: what the
    /// terminal's rows are measured against. Never the card's current height:
    /// its Jump to bottom row, an attachment strip or a long draft come and
    /// go, and sizing the PTY by them resized it each time (user report
    /// 2026-10-14: an inline TUI such as Codex redraws its whole transcript on
    /// every resize, the view moved, Jump to bottom toggled, and the card
    /// resized the PTY again).
    public func restingCardHeight(lineHeight: CGFloat) -> CGFloat {
        let text = lineHeight + 2 * verticalTextInset(lineHeight: lineHeight)
        return max(Self.circle, text.rounded(.up)) + 2 * Self.padding
    }

    /// The text view's top and bottom inset for a font of `lineHeight`.
    public func verticalTextInset(lineHeight: CGFloat) -> CGFloat {
        max(4, ((Self.circle - lineHeight) / 2).rounded(.down))
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
