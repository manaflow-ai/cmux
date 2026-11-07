import AppKit
import CmuxNextDesign

/// A window's toast page on the overlay, with the window's glass under each toast the page draws. The
/// page in the overlay panel cannot blur the window under it, so each toast's glass (the toast surface,
/// opaque under Reduce Transparency) is native, as ``OverlayDialogView``'s card is (review 3 of #37289).
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

    /// Puts the glass at the toasts' rects (this view's coordinates): a resting toast's glass fades in
    /// with it, a fading toast's fades out with it, and one the page no longer draws goes.
    func placeGlass(resting: [(serial: Int, rect: NSRect)], fading leaving: [(serial: Int, rect: NSRect)]) {
        let kept = Set(resting.map(\.serial) + leaving.map(\.serial))
        for (serial, surface) in glass where !kept.contains(serial) {
            surface.removeFromSuperview()
            glass[serial] = nil
            fading.remove(serial)
        }
        for (serial, rect) in resting {
            let surface = glass[serial] ?? makeGlass(serial)
            surface.frame = rect
            if fading.remove(serial) != nil, let layer = surface.layer {
                Motion.overlays.set(layer, "opacity", to: Float(1), fade: .fadeIn)
            }
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

    private func makeGlass(_ serial: Int) -> OverlaySurfaceView {
        let surface = Glass.makeSurface(.toast, cornerRadius: SurfaceRole.toast.cornerRadius, interactive: false)
        surface.translatesAutoresizingMaskIntoConstraints = true
        surface.wantsLayer = true
        addSubview(surface, positioned: .below, relativeTo: page)
        glass[serial] = surface
        if let layer = surface.layer { Motion.overlays.set(layer, "opacity", to: Float(1), fade: .fadeIn, from: Float(0)) }
        return surface
    }
}
