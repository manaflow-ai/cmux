import AppKit

/// cmux: the picture viewer's scroll view. A mouse wheel (line steps: no trackpad, so no pinch) zooms about the
/// pointer, as in Photos, and Command-scroll zooms from either device; a trackpad scroll pans as before (the user,
/// 2026-11-11: "i also want to be able to scroll with my external mouse": on a fitted picture the wheel did nothing).
@MainActor
final class HomePictureScrollView: NSScrollView {
    /// One wheel notch's zoom step.
    static let notch: CGFloat = 1.25

    override func scrollWheel(with event: NSEvent) {
        guard let factor = Self.zoomFactor(event), let document = documentView else { return super.scrollWheel(with: event) }
        let target = min(maxMagnification, max(minMagnification, magnification * factor))
        guard target != magnification else { return }
        setMagnification(target, centeredAt: document.convert(event.locationInWindow, from: nil))
    }

    /// The zoom a wheel event asks for, nil when it pans: a mouse wheel's notches (positive: turned away from the
    /// person, whatever the natural-scrolling setting), or a Command-scroll; one step at most four notches.
    nonisolated static func zoomFactor(_ event: NSEvent) -> CGFloat? {
        let mouse = !event.hasPreciseScrollingDeltas && event.phase.isEmpty && event.momentumPhase.isEmpty
        guard mouse || event.modifierFlags.contains(.command) else { return nil }
        // A trackpad's points are about ten to a notch.
        var notches = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 10 : event.scrollingDeltaY
        if event.isDirectionInvertedFromDevice { notches = -notches }
        guard notches != 0 else { return nil }
        return pow(notch, min(4, max(-4, notches)))
    }
}
