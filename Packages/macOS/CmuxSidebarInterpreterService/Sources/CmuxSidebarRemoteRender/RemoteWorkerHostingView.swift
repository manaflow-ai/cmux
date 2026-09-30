import AppKit
import SwiftUI

/// The worker's hosting view: surfaces AppKit invalidation signals so the
/// coordinator's display pump can commit them.
///
/// In the never-ordered window, SwiftUI/AppKit schedule layout and display
/// work that no display cycle will ever run. Host messages pump explicitly,
/// but work scheduled *between* messages (SwiftUI re-rendering from its own
/// state, deferred display passes) only shows up as `needsLayout`/
/// `needsDisplay` flips here (or as the window's `viewsNeedDisplay`, for
/// descendant views). Forwarding those flips lets the pump turn them into
/// real commits instead of letting them ride the next scene tick.
final class RemoteWorkerHostingView: NSHostingView<RemoteWorkerRootView> {
    /// Fired whenever this view is marked as needing layout or display.
    var onInvalidation: (@MainActor () -> Void)?

    override var needsLayout: Bool {
        didSet {
            if needsLayout { onInvalidation?() }
        }
    }

    override var needsDisplay: Bool {
        didSet {
            if needsDisplay { onInvalidation?() }
        }
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        onInvalidation?()
    }
}
