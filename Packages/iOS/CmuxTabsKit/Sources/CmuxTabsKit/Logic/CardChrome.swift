import Foundation

/// When the tab cards' close buttons and title rows show during the
/// page <-> grid zoom, as measured on Safari (iPhone 17 Pro Max device
/// recordings with real frame timestamps; the measured table is in the
/// cmux-next iOS app's reference/validation/browser.md, round 10):
///
/// - The zooming card's close button rides the card's top-trailing corner at
///   its final size and fades in with the zoom's progress, from 0.76 to 0.96.
/// - Every title row (the zooming card's too) and the other cards' close
///   buttons wait until the zoom reaches 0.96 toward the grid (about 230 ms
///   after a tap), then fade in on their own clock: titles
///   `1 - e^(-t/58 ms)`, close buttons `1 - e^(-(t-16 ms)/45 ms)`, the titles
///   rising 2 pt into place.
/// - Leaving the grid (or a reversal toward the page) hides all of it at
///   once: a 33 ms linear fade from wherever it was.
struct CardChrome: Equatable, Sendable {
    static let zoomCloseStart = 0.76
    static let zoomCloseEnd = 0.96
    static let trigger = 0.96
    static let titleTau = 0.058
    static let closeDelay = 0.016
    static let closeTau = 0.045
    static let fadeOut = 0.033
    static let titleRise: Double = 2

    /// Seconds since the titles started to appear; nil while hidden.
    private(set) var shownFor: Double?
    /// Fading out: seconds since, and the opacities it started from.
    private(set) var hiddenFor: Double?
    private var fromTitle = 0.0
    private var fromClose = 0.0

    /// Advances by `dt` for the zoom state now on screen.
    mutating func step(_ dt: Double, progress: Double, headingToOverview: Bool, settledOnOverview: Bool) {
        let wants = settledOnOverview || (headingToOverview && progress >= Self.trigger - 1e-9)
        if wants {
            hiddenFor = nil
            shownFor = shownFor.map { $0 + dt } ?? 0
        } else if let s = shownFor {
            fromTitle = Self.title(s); fromClose = Self.close(s)
            shownFor = nil
            hiddenFor = dt
        } else if let h = hiddenFor {
            hiddenFor = h + dt
            if h + dt >= Self.fadeOut { hiddenFor = nil }
        }
    }

    /// Jump to the settled look (Reduce Motion, or no animation).
    mutating func settle(onOverview: Bool) {
        hiddenFor = nil
        shownFor = onOverview ? 10 : nil
    }

    var titleOpacity: Double {
        if let s = shownFor { return Self.title(s) }
        if let h = hiddenFor { return fromTitle * max(0, 1 - h / Self.fadeOut) }
        return 0
    }

    var closeOpacity: Double {
        if let s = shownFor { return Self.close(s) }
        if let h = hiddenFor { return fromClose * max(0, 1 - h / Self.fadeOut) }
        return 0
    }

    /// Title row offset below its place (points), 0 when settled.
    var titleOffset: Double { Self.titleRise * (1 - titleOpacity) }

    /// Still changing (the screen keeps its frame clock running).
    var animating: Bool {
        if let s = shownFor { return Self.title(s) < 0.999 || Self.close(s) < 0.999 }
        return hiddenFor != nil
    }

    /// The zooming card's close button, tied to the zoom's progress; hidden
    /// at once when the zoom heads to the page.
    static func zoomCloseOpacity(progress: Double, headingToOverview: Bool) -> Double {
        guard headingToOverview else { return 0 }
        return min(1, max(0, (progress - zoomCloseStart) / (zoomCloseEnd - zoomCloseStart)))
    }

    private static func title(_ t: Double) -> Double { t <= 0 ? 0 : 1 - exp(-t / titleTau) }
    private static func close(_ t: Double) -> Double { t <= closeDelay ? 0 : 1 - exp(-(t - closeDelay) / closeTau) }
}
