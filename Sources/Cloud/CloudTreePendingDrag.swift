import AppKit
import Bonsplit
import Foundation

/// Provisional Cloud drag registration retained until AppKit promotes or drops it.
@MainActor
extension CloudTreeOutlineView.Coordinator {
    final class PendingDrag {
        let registration: CloudTreeDragRegistration
        weak var sourceView: NSOutlineView?
        weak var writer: CloudTreeSurfaceDragPasteboardWriter?

        init(
            registration: CloudTreeDragRegistration,
            sourceView: NSOutlineView,
            writer: CloudTreeSurfaceDragPasteboardWriter? = nil
        ) {
            self.registration = registration
            self.sourceView = sourceView
            self.writer = writer
        }
    }
}
