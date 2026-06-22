import AppKit

final class PortalSplitDividerCacheInvalidator {
    private var observations: [NSKeyValueObservation] = []

    func observe(_ views: [NSView], onChange: @escaping () -> Void) {
        invalidate()
        observations = views.flatMap { view in
            [
                view.observe(\.isHidden, options: [.new]) { _, _ in onChange() },
                view.observe(\.subviews, options: [.new]) { _, _ in onChange() },
            ]
        }
    }

    func invalidate() {
        observations.removeAll()
    }
}
