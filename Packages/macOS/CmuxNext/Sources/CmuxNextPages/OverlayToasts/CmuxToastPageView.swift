import AppKit
import CmuxNextDesign

/// A window's toast page on the overlay, with the window's glass under each toast the page draws. The
/// page in the overlay panel cannot blur the window under it, so each toast's glass (the toast surface:
/// the blur of what is behind the window, opaque under Reduce Transparency) is native, as ``OverlayDialogView``'s card is (review 3 of #37289).
@MainActor
final class CmuxToastPageView: NSView {
    let page: PageWebView
    /// One glass per toast the page reported, by serial.
    private var glass: [Int: OverlaySurfaceView] = [:]
    private var fading: Set<Int> = []

    init(page: PageWebView) {
        self.page = page
        super.init(frame: .zero)
        page.removeFromSuperview()
        page.frame = bounds
        page.autoresizingMask = [.width, .height]
        addSubview(page)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// How far below its slot a new toast starts, in points at zoom 1 (the page's `RISE_PX`).
    static let rise: CGFloat = 8

    /// Puts the glass at the toasts' rects (the page's coordinates, which are flipped: the glass goes where
    /// they show in this view, review 5 of #37289), moving as the page moves the toasts
    /// (useToastMotion): a new toast's glass rises and fades in with it, one that moved slides from where it
    /// was drawn with the same spring (review 4 of #37289), a fading toast's fades out with it, and one the
    /// page no longer draws goes. `zoom` is the page's, for the rise.
    func placeGlass(resting: [(serial: Int, rect: NSRect)], fading leaving: [(serial: Int, rect: NSRect)],
                    zoom: CGFloat = 1) {
        let resting = resting.map { ($0.serial, convert($0.rect, from: page)) }
        let leaving = leaving.map { ($0.serial, convert($0.rect, from: page)) }
        let kept = Set(resting.map(\.0) + leaving.map(\.0))
        var gone: [OverlaySurfaceView] = []
        for (serial, surface) in glass where !kept.contains(serial) {
            glass[serial] = nil
            if fading.remove(serial) == nil { gone.append(surface) } else { surface.removeFromSuperview() }
        }
        defer { gone.forEach { $0.removeFromSuperview() } }
        for (serial, rect) in resting {
            // A toast replaced under its id takes its predecessor's place in one frame (the page's
            // `inPlace`): it keeps that glass, which neither rises nor fades in again (review 5, F3).
            // Its slot is the predecessor's bottom edge; its size may differ (new words).
            if glass[serial] == nil, let index = gone.firstIndex(where: { abs($0.frame.minY - rect.minY) < 0.5 }) {
                let surface = gone.remove(at: index)
                surface.frame = rect
                glass[serial] = surface
                continue
            }
            guard let surface = glass[serial] else {
                let surface = makeGlass(serial)
                surface.frame = rect
                // Up from below its slot (down is -y here unless flipped), as the page's toast rises.
                let below = (isFlipped ? 1 : -1) * Self.rise * zoom
                if let layer = surface.layer {
                    Motion.overlays.set(layer, "transform.translation.y", to: CGFloat(0), spring: .appear, from: below)
                }
                continue
            }
            if fading.remove(serial) != nil, let layer = surface.layer {
                Motion.overlays.set(layer, "opacity", to: Float(1), fade: .fadeIn)
            }
            slide(surface, to: rect)
        }
        for (serial, rect) in leaving {
            guard let surface = glass[serial] else { continue }
            surface.frame = rect
            guard fading.insert(serial).inserted, let layer = surface.layer else { continue }
            Motion.overlays.set(layer, "opacity", to: Float(0), fade: .fadeOut)
        }
    }

    /// The page goes back to its pool: the glass goes with the toasts.
    func releasePage() {
        placeGlass(resting: [], fading: [])
        page.removeFromSuperview()
    }

    /// Moves `surface` to `rect` from where it is drawn now (its frame plus any slide still running).
    private func slide(_ surface: OverlaySurfaceView, to rect: NSRect) {
        let old = surface.frame
        surface.frame = rect
        guard let layer = surface.layer, old.origin != rect.origin else { return }
        for (axis, offset) in [("x", old.minX - rect.minX), ("y", old.minY - rect.minY)] {
            let keyPath = "transform.translation.\(axis)"
            let shown = (Motion.presentationValue(layer, keyPath) as? CGFloat) ?? 0
            Motion.overlays.set(layer, keyPath, to: CGFloat(0), spring: .move, from: shown + offset)
        }
    }

    private func makeGlass(_ serial: Int) -> OverlaySurfaceView {
        let surface = Glass.makeSurface(.toast, cornerRadius: SurfaceRole.toast.cornerRadius, interactive: false)
        // The overlay panel is a clear window over the window it covers: Liquid Glass there has nothing to
        // bend, and its lens drew a dark line and a bevel inside the rim (the Leave site? dialog's edge,
        // Lawrence 2026-11-07). The blur samples what is behind the window, as the dialog card's does.
        surface.samplesBehindWindow = true
        surface.prefersBlurToLiquidGlass = true
        surface.translatesAutoresizingMaskIntoConstraints = true
        surface.wantsLayer = true
        addSubview(surface, positioned: .below, relativeTo: page)
        glass[serial] = surface
        if let layer = surface.layer { Motion.overlays.set(layer, "opacity", to: Float(1), fade: .fadeIn, from: Float(0)) }
        return surface
    }
}
