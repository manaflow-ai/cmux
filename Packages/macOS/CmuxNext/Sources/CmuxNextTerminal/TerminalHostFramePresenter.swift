import CoreFoundation
import GhosttyNextKit
import QuartzCore

/// Puts each resized terminal's frame at its new size into the Core Animation commit that carries the
/// size, when the renderer thread has drawn it by then; it never waits for it
/// (ghostty-integration-DESIGN.md G1).
///
/// A host-sized Ghostty surface draws the frame for a new size on its renderer thread, text reflowed,
/// and hands it to the layer with a main-queue block. That block runs only after the commit when the
/// turn's own display work outlasts the draw (a STRESS layout, many terminals), so the commit showed the
/// old frame clipped or padded. Surfaces resized during a main run-loop turn are collected here; one
/// observer just ahead of the commit asks each for the frame it already has
/// (`ghostty_surface_present_host_frame_ready`). A frame not drawn yet lands as before, one turn later:
/// the waiting present cost the main thread up to 4 ms per drag frame and dropped more frames than it
/// saved. The observer exists only while a turn has a resized surface: nothing runs at rest.
final class TerminalHostFramePresenter {
    /// Core Animation commits at observer order 2,000,000 (``CommitBoundary``); this runs just before.
    static let order: CFIndex = 1_999_999

    private var pending: [ObjectIdentifier: ghostty_surface_t] = [:]
    private var observer: CFRunLoopObserver?
    /// The longest main-thread time one pass took, in seconds (diagnostics and tests).
    private(set) var longestPass: CFTimeInterval = 0

    /// Presents `surface`'s frame at its new size before this turn's commit, if it is drawn by then.
    func sizeChanged(_ surface: ghostty_surface_t, of view: AnyObject) {
        pending[ObjectIdentifier(view)] = surface
        guard observer == nil else { return }
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, false, Self.order) { [weak self] _, _ in
            // main-proof: the observer is added to the main run loop only (below).
            MainActor.assumeIsolated { self?.present() }
        }
        self.observer = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
    }

    /// A surface is freed: it must not be presented.
    func forget(_ view: AnyObject) {
        pending[ObjectIdentifier(view)] = nil
    }

    private func present() {
        let start = CACurrentMediaTime()
        let surfaces = pending
        pending.removeAll(keepingCapacity: true)
        if let observer {
            CFRunLoopObserverInvalidate(observer)
            self.observer = nil
        }
        for surface in surfaces.values { _ = ghostty_surface_present_host_frame_ready(surface) }
        longestPass = max(longestPass, CACurrentMediaTime() - start)
    }
}
