import AppKit
import CmuxNextCompat
import CmuxNextDesign
import QuartzCore

/// The strip's edge fades: a gradient mask on the tabs' clip, shown only while tabs are hidden beyond
/// an edge. The strip holds one and calls `update` after each frame application.
@MainActor final class TabEdgeFade {
    private weak var strip: TabStripView?
    let mask = CAGradientLayer()
    /// Edges whose fade is shown or fading in (`update`).
    private(set) var edges: (leading: Bool, trailing: Bool) = (false, false)

    init(strip: TabStripView) {
        self.strip = strip
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        mask.actions = ["bounds": NSNull(), "position": NSNull(), "colors": NSNull(), "locations": NSNull()]
    }

    /// Fades the strip's ends only while tabs are hidden beyond them: none
    /// on the leading edge at offset 0, none on the trailing edge at the
    /// end, none when every tab fits (rubber band past an end included). An
    /// edge's band fades in or out with the Motion `hover` token (a short
    /// crossfade under Reduce Motion, per the Motion policy); the mask comes off once no edge is faded, so a
    /// strip that fits renders with no offscreen pass.
    func update() {
        guard let strip else { return }
        let fadeMask = mask, tabsClip = strip.tabsClip
        let width = strip.viewportWidth
        let edges = width > 0
            ? TabScrollMath.fadedEdges(offset: strip.scrollOffset, contentWidth: strip.result.contentWidth, viewportWidth: width)
            : (leading: false, trailing: false)
        // The leading fade starts after the fixed pinned band, which never fades.
        let band = min(strip.scrollMapping.band, width)
        let fade = min(strip.metrics.scrollFadeWidth, max(0, width - band) / 2) / max(width, 1)
        let start = band / max(width, 1)
        fadeMask.frame = tabsClip.bounds
        fadeMask.locations = [0, start, start, start + fade, 1 - fade, 1].map { NSNumber(value: Double($0)) }
        guard edges != self.edges else { return }
        let wasFaded = self.edges.leading || self.edges.trailing
        let isFaded = edges.leading || edges.trailing
        self.edges = edges
        let opaque = NSColor.black.cgColor
        let clear = NSColor.clear.cgColor
        let colors = [opaque, opaque, edges.leading ? clear : opaque, opaque, opaque, edges.trailing ? clear : opaque]
        if isFaded, tabsClip.layer?.mask !== fadeMask { tabsClip.layer?.mask = fadeMask }
        let animates = strip.window != nil && (wasFaded || isFaded) && !Motion.isLiveResizing // in a live resize the edge follows at once
        CATransaction.begin()
        CATransaction.setMainCompletion { [weak self] in
            guard let self, let strip = self.strip, !(self.edges.leading || self.edges.trailing) else { return }
            if strip.tabsClip.layer?.mask != nil { strip.tabsClip.layer?.mask = nil }
        }
        if animates {
            // A freshly installed mask starts from fully opaque, not from
            // the colors it had when it came off.
            Motion.tabs.set(fadeMask, "colors", to: colors, fade: .hover, from: wasFaded ? nil : Array(repeating: opaque, count: colors.count))
        } else {
            fadeMask.removeAnimation(forKey: "colors")
            Motion.tabs.transaction(nil) { fadeMask.colors = colors }
        }
        CATransaction.commit()
    }
}
