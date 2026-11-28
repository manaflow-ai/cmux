import CoreGraphics
import Foundation

/// When and how far a held message bubble lifts before Messages' menu opens.
///
/// Messages' transcript opens its menu through UIKit's context-menu click
/// driver (`_UILongPressTimeoutClickInteractionDriver` on
/// `CKTranscriptCollectionView`, read from the iOS 26.5 and 27.0 simulator
/// runtimes): `minimumDurationRequired` 0.15 s, `clickDownDuration` 0.4 s,
/// `clickTimeoutDuration` 0.725 s, `clicksUpAutomaticallyAfterTimeout`.
/// So the bubble starts growing 0.15 s into the press; lifting the finger
/// before 0.4 s lets it settle back with no menu; lifting between 0.4 s and
/// 0.725 s opens the menu at the lift; holding opens it at 0.725 s.
///
/// The growth is a fixed number of points on the bubble's long side, not a
/// fixed factor (measured on iOS 26.5 Messages, 60 fps): a 208 pt bubble
/// grows to 222.7 pt while held and lifts to 234.5 pt with the menu; a
/// 278 pt bubble to 291.5 pt and 303.5 pt. A small bubble lifts no more
/// than 1.15 times its size (69.7 -> 80 pt, 83.3 -> 96 pt, 119.7 -> 137 pt).
// lint:allow namespace-type -- vendored CmuxConversation snapshot
public enum MessagePressTiming {
    public static let liftBegins: TimeInterval = 0.15
    public static let clickDown: TimeInterval = 0.4
    public static let clickTimeout: TimeInterval = 0.725
    /// Points the long side grows while the press is held.
    public static let pressGrowth: CGFloat = 14
    /// Points the long side grows once the menu opens.
    public static let liftGrowth: CGFloat = 26
    /// The largest scale a lifted bubble reaches, however small it is.
    public static let maxLiftScale: CGFloat = 1.15
    /// The held growth follows `1 - exp(-t / 0.27 s)` from `liftBegins` to
    /// `clickTimeout` (fitted to iOS 26.5 and 27.0 Messages frame by frame,
    /// within 0.07 of progress); this cubic matches that within 1 %.
    public static let pressCurve = (CGPoint(x: 0.32, y: 0.85), CGPoint(x: 0.95, y: 1))

    public enum Release: Equatable, Sendable {
        /// The bubble settles back; no menu.
        case cancel
        /// The menu opens now.
        case open
    }

    /// What lifting the finger does after holding for `elapsed` seconds.
    public static func release(afterHolding elapsed: TimeInterval) -> Release {
        elapsed >= clickDown ? .open : .cancel
    }

    /// The transcript's touch handlers, as the press arbitrates them.
    public enum Gesture: Equatable, Sendable {
        /// Either press clock (growth start or click timeout).
        case press
        /// A single or double tap: opening a photo, file, link, link card,
        /// mention card, tapback detail, poll vote, thread, or the tapback bar.
        case tap
        /// A scroll or swipe.
        case pan
        case other
    }

    /// Whether `a` and `b` may both recognize on one touch. The two press
    /// clocks run together; while the bubble only grows a drag may still
    /// scroll or swipe (it cancels the press); taps share every touch and
    /// decide at the lift with `tapOpensItem`.
    public static func recognizeTogether(_ a: Gesture, _ b: Gesture, isGrowing: Bool) -> Bool {
        switch (a, b) {
        case (.press, .press): return true
        case (.press, .pan), (.pan, .press): return isGrowing
        case (.tap, _), (_, .tap): return true
        default: return false
        }
    }

    /// Whether a tap that lifts after `held` seconds opens what it hit.
    /// Messages (iOS 26.5, photo bubble): a lift before the click opens the
    /// item even though the bubble started growing (0.13 to 0.36 s holds); a
    /// lift at or after the click opens the menu instead, never the item.
    public static func tapOpensItem(afterHolding held: TimeInterval) -> Bool {
        held < clickDown
    }

    /// Scale of a held bubble of `size` just before the menu opens.
    public static func pressScale(for size: CGSize) -> CGFloat {
        scale(for: size, growth: pressGrowth)
    }

    /// Scale of the lifted bubble while the menu is open.
    public static func liftScale(for size: CGSize) -> CGFloat {
        min(scale(for: size, growth: liftGrowth), maxLiftScale)
    }

    private static func scale(for size: CGSize, growth: CGFloat) -> CGFloat {
        let side = max(size.width, size.height)
        guard side > 0 else { return 1 }
        return 1 + growth / side
    }
}
