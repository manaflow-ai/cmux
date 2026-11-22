import AppKit
import CmuxNextDesign

// Icons that carry no news stay out of sight until the pointer is on the bar or the bar has the keyboard (Lawrence
// 2026-11-21, "drastically simplify all parts of the UI"): the site-info chip of a secure page and the hollow star of a
// page not bookmarked. They keep their room, faded to clear, so their coming and going moves no text. A page that is not
// secure keeps its "Not secure" chip, and a bookmarked page its filled star.
extension AddressBarView {
    /// The site-info chip says nothing a person needs at rest: a secure web page's neutral icon, with no label.
    var chipIsQuiet: Bool {
        chip.indicator.symbol == PageInfoIndicator.secureSymbol && chip.indicator.label == nil && chip.indicator.tone == .neutral
    }

    /// The star says nothing a person needs at rest: the page is not bookmarked.
    var starIsQuiet: Bool { starButton.state == .off }

    /// Whether the quiet icons show: the pointer is on the bar, or the bar has the keyboard.
    var showsQuietIcons: Bool { pill.debugHovering || controller.state.hasFocus }

    /// Fades the quiet icons in or out; `fade` nil sets them at once (a page or focus change).
    func updateQuietIcons(fade: MotionFade?) {
        let shown = showsQuietIcons
        for (view, quiet) in [(chip as NSView, chipIsQuiet), (starButton as NSView, starIsQuiet)] {
            let alpha: CGFloat = quiet && !shown ? 0 : 1
            guard view.alphaValue != alpha else { continue }
            if let fade {
                Motion.feedback.animate(fade, in: view) { view.animator().alphaValue = alpha }
            } else {
                view.alphaValue = alpha
            }
        }
    }
}
