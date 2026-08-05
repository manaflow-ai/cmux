import SwiftUI

/// Keeps the AppKit drop target outside unrelated panel render updates. The
/// routing context changes only when this panel moves, is replaced, or becomes
/// hidden, so SwiftUI can preserve the representable and its registered view.
struct PaneDropTargetOverlaySnapshot: View, Equatable {
    let dropContext: PaneDropContext?

    @ViewBuilder
    var body: some View {
        if let dropContext {
            PaneDropTargetRepresentable(dropContext: dropContext)
        }
    }
}
