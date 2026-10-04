import AppKit
import ObjectiveC

/// Tells the dialog center when a tab's view deallocates: a closed tab,
/// pane or workspace ends every dialog scoped to it (no dialog outlives its
/// scope). A tab switch keeps the view, so it does not end the dialog. The
/// marker rides on the view as an associated object and fires from its
/// deinit, which runs when the view deallocates.
nonisolated final class CmuxDialogScopeLifetime: @unchecked Sendable {
    let token = UUID()
    private let onEnd: @Sendable (UUID) -> Void

    private init(onEnd: @escaping @Sendable (UUID) -> Void) {
        self.onEnd = onEnd
    }

    deinit { onEnd(token) }

    /// All markers of one view (associated as one object).
    private final class Bag: @unchecked Sendable {
        var markers: [CmuxDialogScopeLifetime] = []
    }

    nonisolated(unsafe) private static var bagKey: UInt8 = 0

    /// Attaches a marker to `view`; `onEnd` runs with its token when `view`
    /// deallocates.
    @MainActor
    static func attach(to view: NSView, onEnd: @escaping @Sendable (UUID) -> Void) -> UUID {
        let marker = CmuxDialogScopeLifetime(onEnd: onEnd)
        let bag = withUnsafePointer(to: &bagKey) { key in
            if let existing = objc_getAssociatedObject(view, key) as? Bag { return existing }
            let bag = Bag()
            objc_setAssociatedObject(view, key, bag, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return bag
        }
        bag.markers.append(marker)
        return marker.token
    }
}
