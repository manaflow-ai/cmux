import SwiftUI

private struct InternalTabDragConfigurationModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            // These drags only make sense inside cmux. Outside the app, Finder
            // should reject them instead of materializing placeholder files from
            // the payload. Built inline (not a static) so package strict
            // concurrency does not flag a non-Sendable global.
            content.dragConfiguration(
                DragConfiguration(
                    operationsWithinApp: .init(allowCopy: false, allowMove: true, allowDelete: false),
                    operationsOutsideApp: .init(allowCopy: false, allowMove: false, allowDelete: false)
                )
            )
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension View {
    /// Marks a draggable sidebar view as internal-only so the OS rejects the
    /// drag outside the app instead of materializing placeholder files from the
    /// payload.
    ///
    /// Drained byte-identically from the app target's
    /// `Sources/Sidebar/InternalTabDragConfiguration.swift` so the browser-stack
    /// row and tile views in this package keep the identical drag policy without
    /// reaching back into the app module.
    func internalOnlyTabDrag() -> some View {
        modifier(InternalTabDragConfigurationModifier())
    }
}
