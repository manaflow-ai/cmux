import Foundation
import SwiftUI

extension View {
    /// Applies the row's drag source only when not editing inline. While
    /// editing, no drag session can begin, so drag-to-select inside the rename
    /// field never starts a sidebar reorder.
    @ViewBuilder
    func sidebarRowDragGate(isEditing: Bool, _ makeProvider: @escaping () -> NSItemProvider) -> some View {
        if isEditing {
            self
        } else {
            onDrag(makeProvider)
        }
    }
}
