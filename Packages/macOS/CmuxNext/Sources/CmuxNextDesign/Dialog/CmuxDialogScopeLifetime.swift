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

    /// Each view's bag of markers.
    private static let bags = ObjectAssociation<Bag>()

    /// Attaches a marker to `view`; `onEnd` runs with its token when `view`
    /// deallocates.
    @MainActor
    static func attach(to view: NSView, onEnd: @escaping @Sendable (UUID) -> Void) -> UUID {
        let marker = CmuxDialogScopeLifetime(onEnd: onEnd)
        let bag: Bag
        if let existing = bags.value(on: view) {
            bag = existing
        } else {
            bag = Bag()
            bags.set(bag, on: view)
        }
        bag.markers.append(marker)
        return marker.token
    }
}
