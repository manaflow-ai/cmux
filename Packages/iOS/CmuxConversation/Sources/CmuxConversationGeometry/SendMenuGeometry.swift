import CoreGraphics
import Foundation

/// The composer's "+" menu (ChatKit's send menu popover), as iOS 26.5 and
/// 27.0 Messages lay it out and animate it on iPhone. Every constant below was
/// read from `CKUIBehavior` at runtime in those simulators (the two releases
/// agree), and the frames were checked against MobileSMS recordings.
public enum SendMenuGeometry {
    /// `sendMenuPrototypeCellMaximumWidth`: the popover is never wider.
    public static let maximumWidth: CGFloat = 320
    /// Gap between the popover and the safe area's edges.
    public static let edgeInset: CGFloat = 10
    /// One row: `sendMenuListItemIconSize` 54 plus `sendMenuListItemIconVerticalPadding` 6 each side.
    public static let rowHeight: CGFloat = 66
    public static let iconSize: CGFloat = 54
    /// `sendMenuListItemIconToEdgePadding`.
    public static let iconLeading: CGFloat = 27
    /// `sendMenuListItemIconToLabelPadding`.
    public static let iconToLabel: CGFloat = 18
    /// Space above the first row; `sendMenuCollectionViewBottomContentInset` below the last.
    public static let verticalInset: CGFloat = 21
    /// `sendMenuPreferredNumberOfItemsToDisplayOnOpen`: a longer list scrolls,
    /// with the 7th row cut in half to show there is more.
    public static let maximumVisibleRows: CGFloat = 6.6
    /// `sendMenuListItemFont`: SF 24 regular.
    public static let labelFontSize: CGFloat = 24
    /// Corner radius of the open popover, fitted to the recorded outline.
    public static let cornerRadius: CGFloat = 32
    /// `sendMenuPlusSymbolScale`: the "+" grows to this while it fades out.
    public static let plusSymbolScale: CGFloat = 2

    /// Corner radius part way through the morph: the "+" circle stays round
    /// (a capsule of the shorter side) as it grows and only settles into the
    /// menu's corners as it reaches its height, as in the recorded frames.
    public static func cornerRadius(for size: CGSize, closed: CGSize, open: CGSize) -> CGFloat {
        let round = min(size.width, size.height) / 2
        let span = open.height - closed.height
        let progress = span == 0 ? 1 : min(max((size.height - closed.height) / span, 0), 1)
        return min(round + (cornerRadius - round) * progress, round)
    }

    /// Height of a popover listing `itemCount` rows.
    public static func height(itemCount: Int) -> CGFloat {
        let rows = CGFloat(itemCount)
        if rows > maximumVisibleRows { return verticalInset + maximumVisibleRows * rowHeight }
        return verticalInset + rows * rowHeight + verticalInset
    }

    /// Space kept above the bottom safe area: 10 pt on iOS 26, none on iOS 27
    /// (the same 456.6 pt menu sits at y 373 on 26.5 and y 383.3 on 27.0).
    public static func bottomInset(iOS27: Bool) -> CGFloat { iOS27 ? 0 : edgeInset }

    /// The open popover: centered vertically on the "+" button, kept inside
    /// `bounds` less the safe area, `edgeInset` and `bottomInset` (Messages
    /// measured on iOS 26.5: a 456.6 pt menu at y 373 above an iPhone 17
    /// Pro's home indicator; on 27.0, at y 281 centered on a "+" raised by
    /// the keyboard).
    public static func openFrame(anchor: CGRect, in bounds: CGRect, safeArea: (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat), itemCount: Int, bottomInset: CGFloat = edgeInset) -> CGRect {
        let minX = bounds.minX + safeArea.left + edgeInset
        let maxX = bounds.maxX - safeArea.right - edgeInset
        let width = min(maximumWidth, maxX - minX)
        let minY = bounds.minY + safeArea.top + edgeInset
        let maxY = bounds.maxY - safeArea.bottom - bottomInset
        let height = min(height(itemCount: itemCount), maxY - minY)
        var y = anchor.midY - height / 2
        y = min(y, maxY - height)
        y = max(y, minY)
        return CGRect(x: minX, y: y.rounded(.down), width: width, height: height)
    }

    /// The frame while a downward swipe drags the open menu: it shrinks
    /// toward the "+" button, half way after `dragDistance` points
    /// (Messages: a 320 pt menu was 180 pt wide after a 306 pt drag).
    public static func draggedFrame(open: CGRect, anchor: CGRect, translation: CGFloat) -> CGRect {
        let progress = dragProgress(translation: translation)
        return interpolate(open, anchor, progress)
    }

    public static let dragDistance: CGFloat = 612

    /// Fraction of the way from the open frame to the "+" button, 0 to 0.9.
    public static func dragProgress(translation: CGFloat) -> CGFloat {
        min(max(translation / dragDistance, 0), 0.9)
    }

    public static func interpolate(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(
            x: a.minX + (b.minX - a.minX) * t,
            y: a.minY + (b.minY - a.minY) * t,
            width: a.width + (b.width - a.width) * t,
            height: a.height + (b.height - a.height) * t
        )
    }

    /// A `UISpringTimingParameters(mass:stiffness:damping:initialVelocity:)`.
    public struct Spring: Sendable, Equatable {
        public var mass: CGFloat
        public var stiffness: CGFloat
        public var damping: CGFloat
        public var velocity: CGVector
        /// UIKit's implicit duration for these parameters, as ChatKit's
        /// animators report it: when the motion has settled.
        public var settlingDuration: Double
        /// `addAnimations(_:delayFactor:)` for the horizontal tracks.
        public var delayFactor: CGFloat = 0

        public init(mass: CGFloat, stiffness: CGFloat, damping: CGFloat, velocity: CGVector = .zero, settlingDuration: Double, delayFactor: CGFloat = 0) {
            self.mass = mass
            self.stiffness = stiffness
            self.damping = damping
            self.velocity = velocity
            self.settlingDuration = settlingDuration
            self.delayFactor = delayFactor
        }

        public var dampingRatio: CGFloat { damping / (2 * (stiffness * mass).squareRoot()) }

        /// Delay before the track moves, for an animator of this spring
        /// whose duration is its settling time.
        public var delay: Double { Double(delayFactor) * settlingDuration }

        /// Progress from 0 to 1 (overshooting when underdamped) `t` seconds
        /// after the delay. `velocity.dx`, in units of the whole distance
        /// per second, starts it moving, as UIKit applies it to a scalar.
        public func progress(at t: Double, initialVelocity v0: CGFloat? = nil) -> CGFloat {
            guard t > 0 else { return 0 }
            let v = Double(v0 ?? velocity.dx)
            let omega = Double((stiffness / mass).squareRoot())
            let zeta = Double(dampingRatio)
            let x: Double
            if zeta < 1 {
                let wd = omega * (1 - zeta * zeta).squareRoot()
                x = exp(-zeta * omega * t) * (cos(wd * t) + (zeta * omega - v) / wd * sin(wd * t))
            } else if zeta == 1 {
                x = exp(-omega * t) * (1 + (omega - v) * t)
            } else {
                let r = omega * (zeta * zeta - 1).squareRoot()
                let r1 = -zeta * omega + r, r2 = -zeta * omega - r
                // x(0) = 1, x'(0) = -v
                let c2 = (-v - r1) / (r2 - r1)
                let c1 = 1 - c2
                x = c1 * exp(r1 * t) + c2 * exp(r2 * t)
            }
            return CGFloat(1 - x)
        }
    }

    /// Opening. ChatKit's `newSendMenuPresentPopover{Width,CenterX}Animator`
    /// (m2 k300 c36, delayFactor 0.025) and `{Height,CenterY}Animator`
    /// (m2 k320 c35) are not what the screen shows: in a clean 60 fps
    /// recording of MobileSMS on iOS 27.0 every edge of the menu follows
    /// omega 17.3, zeta 0.81 (89% in 10 frames, then a 1% overshoot), and the
    /// iOS 26.5 recording agrees. Widening trails rising by about a frame
    /// (ChatKit adds its horizontal tracks with a delayFactor).
    public enum Present {
        public static let horizontal = Spring(mass: 1, stiffness: 300, damping: 28, settlingDuration: 0.5, delayFactor: 0.05)
        public static let vertical = Spring(mass: 1, stiffness: 300, damping: 28, settlingDuration: 0.5)
        /// `newSendMenuPresentPopoverPlusIcon{Opacity,BlurRadius}Animator`.
        public static let plusFade = Spring(mass: 1, stiffness: 2706, damping: 104, settlingDuration: 0.2026780)
        /// `newSendMenuPresentPopoverAnimator`, `sendMenuIconBlurAppearanceAnimator`.
        public static let content = Spring(mass: 2, stiffness: 300, damping: 50, settlingDuration: 0.7540376)
        /// The grown "+" stays solid and the rows stay hidden this long
        /// while the circle swells (5-6 frames in the iOS 26.5 and 27.0
        /// recordings: ChatKit fades them once the menu's list has loaded).
        public static let contentDelay: Double = 0.09
    }

    /// Closing (tap outside, an item, a swipe). ChatKit's
    /// `newSendMenuDismissPopover*Animator` springs (m2 k300 c50 / c47) are
    /// not what MobileSMS shows either: the 27.0 recording folds back into
    /// the "+" in 12 frames (omega 21-22, zeta 0.82-0.87), which is
    /// ChatKit's `sendMenuStatusBarAnimator` spring.
    public enum Dismiss {
        public static let geometry = Spring(mass: 1, stiffness: 443, damping: 36, settlingDuration: 0.4379076)
        public static let horizontal = geometry
        public static let vertical = geometry
        public static let plusOpacity = geometry
        public static let content = geometry
    }
}
