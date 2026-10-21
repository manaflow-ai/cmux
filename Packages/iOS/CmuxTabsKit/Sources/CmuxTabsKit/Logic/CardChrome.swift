import Foundation

/// When the tab cards' close buttons and title rows show during the
/// page <-> grid zoom, as measured on Safari (iPhone 17 Pro Max device
/// recordings with real frame timestamps; the measured table is in the
/// cmux-next iOS app's reference/validation/browser.md, rounds 10 and 11):
///
/// - The zooming card's close button rides the card's top-trailing corner at
///   its final size and fades in with the zoom's progress, from 0.76 to 0.96.
/// - The other cards' close buttons wait until the zoom reaches 0.96 toward
///   the grid (about 230 ms after a tap), then fade in on their own clock:
///   `1 - e^(-(t-16 ms)/45 ms)`.
/// - Every title row (the zooming card's too) fades in the same way,
///   `1 - e^(-t/58 ms)`, rising 2 pt into place. Safari starts them at 0.96
///   too; ours start at `titleTrigger` (0.90, about 50 ms sooner), a
///   deliberate deviation asked for on device.
/// - Leaving the grid (or a reversal toward the page) hides all of it at
///   once: a 33 ms linear fade from wherever it was.
struct CardChrome: Equatable, Sendable {
    static let zoomCloseStart = 0.76
    static let zoomCloseEnd = 0.96
    /// Progress toward the grid at which the title rows start to fade in.
    /// Safari: 0.96; these start sooner on purpose (asked for on device).
    static let titleTrigger = 0.90
    /// Progress toward the grid at which the other cards' close buttons start.
    static let closeTrigger = 0.96
    static let titleTau = 0.058
    static let closeDelay = 0.016
    static let closeTau = 0.045
    static let fadeOut = 0.033
    static let titleRise: Double = 2

    /// One fading element: seconds since it started to appear, or a fade-out
    /// in progress from the opacity it had.
    struct Channel: Equatable, Sendable {
        var shownFor: Double?
        var hiddenFor: Double?
        var from = 0.0

        mutating func step(_ dt: Double, wants: Bool, curve: (Double) -> Double) {
            if wants {
                hiddenFor = nil
                shownFor = shownFor.map { $0 + dt } ?? 0
            } else if let s = shownFor {
                from = curve(s)
                shownFor = nil
                hiddenFor = dt
            } else if let h = hiddenFor {
                hiddenFor = h + dt >= CardChrome.fadeOut ? nil : h + dt
            }
        }

        func opacity(_ curve: (Double) -> Double) -> Double {
            if let s = shownFor { return curve(s) }
            if let h = hiddenFor { return from * max(0, 1 - h / CardChrome.fadeOut) }
            return 0
        }

        func animating(_ curve: (Double) -> Double) -> Bool {
            if let s = shownFor { return curve(s) < 0.999 }
            return hiddenFor != nil
        }
    }

    private(set) var title = Channel()
    private(set) var close = Channel()

    /// Advances by `dt` for the zoom state now on screen.
    mutating func step(_ dt: Double, progress: Double, headingToOverview: Bool, settledOnOverview: Bool) {
        let toward = headingToOverview || settledOnOverview
        title.step(dt, wants: settledOnOverview || (toward && progress >= Self.titleTrigger - 1e-9), curve: Self.titleCurve)
        close.step(dt, wants: settledOnOverview || (toward && progress >= Self.closeTrigger - 1e-9), curve: Self.closeCurve)
    }

    /// Jump to the settled look (Reduce Motion, or no animation).
    mutating func settle(onOverview: Bool) {
        title = Channel(shownFor: onOverview ? 10 : nil)
        close = Channel(shownFor: onOverview ? 10 : nil)
    }

    var titleOpacity: Double { title.opacity(Self.titleCurve) }
    var closeOpacity: Double { close.opacity(Self.closeCurve) }

    /// Title row offset below its place (points), 0 when settled.
    var titleOffset: Double { Self.titleRise * (1 - titleOpacity) }

    /// Still changing (the screen keeps its frame clock running).
    var animating: Bool { title.animating(Self.titleCurve) || close.animating(Self.closeCurve) }

    /// The zooming card's close button, tied to the zoom's progress; hidden
    /// at once when the zoom heads to the page.
    static func zoomCloseOpacity(progress: Double, headingToOverview: Bool) -> Double {
        guard headingToOverview else { return 0 }
        return min(1, max(0, (progress - zoomCloseStart) / (zoomCloseEnd - zoomCloseStart)))
    }

    static func titleCurve(_ t: Double) -> Double { t <= 0 ? 0 : 1 - exp(-t / titleTau) }
    static func closeCurve(_ t: Double) -> Double { t <= closeDelay ? 0 : 1 - exp(-(t - closeDelay) / closeTau) }
}
