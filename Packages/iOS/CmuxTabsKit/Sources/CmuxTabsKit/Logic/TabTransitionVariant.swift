#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Foundation

/// The taste of the page <-> tab overview zoom transition: its springs, the
/// grid's settle animation, and how the zooming card's corner radius and
/// shadow grow with progress. `safari` is today's look and the default;
/// the others are for side-by-side review (Leo, 2026-11-25: "make it
/// smooth!"). Pick one with the launch argument `-tabs-transition NAME`
/// (also a `tabs-transition` user default) or `CMUX_TABS_TRANSITION=NAME`.
///
/// Every variant keeps the hand-off rules: the zoom retargets from its
/// current position and velocity, and the card frame and the page frame
/// match where the zoom settles (`ZoomPresentation`).
struct TabTransitionVariant: Equatable, Sendable {
    var name: String
    /// Page to card (tabs button) and card to page (Done, a card) when the
    /// curve is not replayed.
    var toOverview: ZoomSpring
    var toPage: ZoomSpring
    /// A tap mid-flight retargets onto these, keeping position and velocity.
    var retargetToPage: ZoomSpring
    var retargetToOverview: ZoomSpring
    /// After a pinch is released.
    var release: ZoomSpring
    /// A tap from rest replays Safari's recorded curves (`SafariCurve`).
    var replaysSafariCurve: Bool
    /// The grid's settle animation: it starts `1 + settleScale` large and
    /// `settleBlur` points blurred and comes to 1 and sharp as it shows.
    var settleScale: Double
    var settleBlur: Double
    /// The zooming card's corner radius: screen radius to card radius along
    /// `q^radiusExponent` (1 is linear; below 1 rounds early).
    var radiusExponent: Double
    /// The zooming card's shadow is off until this progress, then grows
    /// linearly to the grid cards' shadow at the card.
    var shadowStart: Double

    /// Today's look: Safari's fitted springs and curves, the grid settling
    /// from 1.06 and 10 pt of blur (vocabulary §6 variant A).
    static let safari = TabTransitionVariant(
        name: "safari", toOverview: .toOverview, toPage: .toPage,
        retargetToPage: .reversalToPage, retargetToOverview: .reversalToOverview, release: .release,
        replaysSafariCurve: true, settleScale: 0.06, settleBlur: 10, radiusExponent: 1, shadowStart: 0)

    /// Springs all the way (no replayed curve), a touch of bounce at the
    /// card, half the blur, corners that round early and a shadow that
    /// comes in over the second half.
    static let soft = TabTransitionVariant(
        name: "soft", toOverview: ZoomSpring(response: 0.42, damping: 0.82), toPage: ZoomSpring(response: 0.4, damping: 0.92),
        retargetToPage: ZoomSpring(response: 0.38, damping: 0.92), retargetToOverview: ZoomSpring(response: 0.4, damping: 0.84),
        release: ZoomSpring(response: 0.4, damping: 0.86),
        replaysSafariCurve: false, settleScale: 0.04, settleBlur: 5, radiusExponent: 0.6, shadowStart: 0.5)

    /// Critically damped and quicker, no blur: the grid only scales in
    /// (vocabulary §6 variant B), and the shadow arrives near the card.
    static let crisp = TabTransitionVariant(
        name: "crisp", toOverview: ZoomSpring(response: 0.3, damping: 1), toPage: ZoomSpring(response: 0.3, damping: 1),
        retargetToPage: ZoomSpring(response: 0.28, damping: 1), retargetToOverview: ZoomSpring(response: 0.28, damping: 1),
        release: ZoomSpring(response: 0.3, damping: 1),
        replaysSafariCurve: false, settleScale: 0.03, settleBlur: 0, radiusExponent: 1, shadowStart: 0.7)

    /// Safari's motion with no settle animation on the grid: it stays put
    /// and sharp while the card flies (vocabulary §6 variant D).
    static let still = TabTransitionVariant(
        name: "still", toOverview: .toOverview, toPage: .toPage,
        retargetToPage: .reversalToPage, retargetToOverview: .reversalToOverview, release: .release,
        replaysSafariCurve: true, settleScale: 0, settleBlur: 0, radiusExponent: 1, shadowStart: 0)

    static let all: [TabTransitionVariant] = [.safari, .soft, .crisp, .still]

    /// The variant called `name`, or the default for nil or an unknown name.
    static func named(_ name: String?) -> TabTransitionVariant {
        guard let name = name?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty else { return .safari }
        return all.first { $0.name == name } ?? .safari
    }

    /// The launch argument `-tabs-transition NAME` (Foundation puts it in
    /// the argument domain of `UserDefaults`), else `CMUX_TABS_TRANSITION`.
    static func fromEnvironment(defaults: UserDefaults = .standard,
                                environment: [String: String] = ProcessInfo.processInfo.environment) -> TabTransitionVariant {
        named(defaults.string(forKey: "tabs-transition") ?? environment["CMUX_TABS_TRANSITION"])
    }

    // MARK: Curves

    /// The grid's scale for how far it shows (0 hidden, 1 settled).
    func gridScale(shown: Double) -> Double { 1 + settleScale * (1 - clamp(shown)) }
    func gridBlur(shown: Double) -> Double { settleBlur * (1 - clamp(shown)) }

    /// The zooming card's corner radius at `progress`.
    func radius(progress: Double, screen: CGFloat, card: CGFloat) -> CGFloat {
        screen + (card - screen) * CGFloat(pow(clamp(progress), radiusExponent))
    }

    /// The zooming card's shadow, as a fraction of the grid cards' shadow.
    func shadow(progress: Double) -> Double {
        let q = clamp(progress)
        guard shadowStart < 1 else { return q >= 1 ? 1 : 0 }
        return max(0, (q - shadowStart) / (1 - shadowStart))
    }

    private func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
}

/// Where the active tab's page layer is drawn, as one value for every phase:
/// full screen on the settled page, the zoom's rect while it moves, and its
/// card on the settled grid. Settled on the grid the rect is in the grid's
/// content coordinates and follows its scroll (`followsGrid`), so a scroll
/// frame moves it without rebuilding the page.
struct ZoomPresentation: Equatable, Sendable {
    var rect: CGRect
    var radius: CGFloat
    /// The card shadow's opacity, as a fraction of the grid cards' shadow.
    var shadow: Double
    /// `rect` is in grid content coordinates; add the grid's screen origin.
    var followsGrid: Bool

    /// The rect on screen, given where grid content point (0, 0) is now.
    func screenRect(gridOrigin: CGPoint) -> CGRect {
        followsGrid ? rect.offsetBy(dx: gridOrigin.x, dy: gridOrigin.y) : rect
    }

    /// - Parameters:
    ///   - card: the active card in the grid's content coordinates.
    ///   - gridOrigin: where grid content point (0, 0) is on screen (the
    ///     zoom's card end is `card` moved there, as the settled card is).
    ///   - settledPageRadius: the page's corner radius at rest (0, or the
    ///     screen's during a toolbar swipe).
    static func make(phase: TabZoomState.Phase, progress: Double, offset: CGVector, full: CGRect, card: CGRect,
                     gridOrigin: CGPoint, screenRadius: CGFloat, cardRadius: CGFloat, settledPageRadius: CGFloat,
                     variant: TabTransitionVariant) -> ZoomPresentation {
        switch phase {
        case .page:
            return ZoomPresentation(rect: full, radius: settledPageRadius, shadow: 0, followsGrid: false)
        case .overview:
            return ZoomPresentation(rect: card, radius: cardRadius, shadow: 1, followsGrid: true)
        case .animating, .interactive:
            let path = ZoomRectPath(full: full, card: card.offsetBy(dx: gridOrigin.x, dy: gridOrigin.y))
            return ZoomPresentation(rect: path.rect(progress: progress, offset: offset),
                                    radius: variant.radius(progress: progress, screen: screenRadius, card: cardRadius),
                                    shadow: variant.shadow(progress: progress), followsGrid: false)
        }
    }

    static func make(_ s: TabZoomState, full: CGRect, card: CGRect, gridOrigin: CGPoint, screenRadius: CGFloat,
                     cardRadius: CGFloat, settledPageRadius: CGFloat = 0, variant: TabTransitionVariant) -> ZoomPresentation {
        make(phase: s.phase, progress: s.progress, offset: s.offset, full: full, card: card, gridOrigin: gridOrigin,
             screenRadius: screenRadius, cardRadius: cardRadius, settledPageRadius: settledPageRadius, variant: variant)
    }
}
