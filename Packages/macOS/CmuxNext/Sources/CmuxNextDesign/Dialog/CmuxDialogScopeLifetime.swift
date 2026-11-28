import AppKit
import ObjectiveC

/// Tells the dialog center when a tab's view deallocates: a closed tab,
/// pane or workspace ends every dialog scoped to it (no dialog outlives its
/// scope). A tab switch keeps the view, so it does not end the dialog. The
/// marker rides on the view as an associated object and fires from its
/// deinit, which runs when the view deallocates.
nonisolated final class CmuxDialogScopeLifetime: Sendable {
    let token = UUID()
    private let onEnd: @Sendable (UUID) -> Void

    private init(onEnd: @escaping @Sendable (UUID) -> Void) {
        self.onEnd = onEnd
    }

    deinit { onEnd(token) }

    /// All markers of one view (associated as one object; touched only on
    /// the main actor).
    @MainActor private final class Bag {
        var markers: [CmuxDialogScopeLifetime] = []
    }

    /// The associated-object key: one byte allocated once, never freed.
    @MainActor private static let bagKey = UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))

    /// Attaches a marker to `view`; `onEnd` runs with its token when `view`
    /// deallocates.
    @MainActor
    static func attach(to view: NSView, onEnd: @escaping @Sendable (UUID) -> Void) -> UUID {
        let marker = CmuxDialogScopeLifetime(onEnd: onEnd)
        let bag: Bag
        if let existing = objc_getAssociatedObject(view, bagKey) as? Bag {
            bag = existing
        } else {
            bag = Bag()
            objc_setAssociatedObject(view, bagKey, bag, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        bag.markers.append(marker)
        return marker.token
    }
}
