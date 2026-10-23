import CoreFoundation
import GhosttyNextKit

/// Presents each resized terminal's frame at its new size in the Core Animation commit that
/// carries the size (ghostty-integration-DESIGN.md G1).
///
/// A host-sized Ghostty surface draws the frame for a new size on its renderer thread, with the
/// text reflowed to the new grid. Its layer gets no display pass for the size change (measured: 0
/// passes in a divider drag), so without this the commit showed the last frame, clipped or padded,
/// and the new one landed a turn or more later. Surfaces resized during a main run-loop turn are
/// collected here; one observer, just ahead of Core Animation's commit observer, asks each for its
/// frame (`ghostty_surface_present_host_frame`: a bounded wait shared by all of them, since every
/// renderer started when its size was set). The observer exists only while a turn has a resized
/// surface: nothing runs at rest.
final class TerminalHostFramePresenter {
    /// Core Animation commits at observer order 2,000,000 (``CommitBoundary``); this runs just before.
    static let order: CFIndex = 1_999_999

    private var pending: [ObjectIdentifier: ghostty_surface_t] = [:]
    private var observer: CFRunLoopObserver?

    /// Presents `surface`'s frame at its new size before this turn's commit.
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
        let surfaces = pending
        pending.removeAll(keepingCapacity: true)
        if let observer {
            CFRunLoopObserverInvalidate(observer)
            self.observer = nil
        }
        for surface in surfaces.values { _ = ghostty_surface_present_host_frame(surface) }
    }
}
