import SwiftUI

#if compiler(>=6.2)
@available(macOS 26.0, *)
enum InternalTabDragConfigurationProvider {
    // These drags only make sense inside cmux. Outside the app, Finder should
    // reject them instead of materializing placeholder files from the payload.
    static let value = DragConfiguration(
        operationsWithinApp: .init(allowCopy: false, allowMove: true, allowDelete: false),
        operationsOutsideApp: .init(allowCopy: false, allowMove: false, allowDelete: false)
    )
}
#endif

private struct InternalTabDragConfigurationModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.dragConfiguration(InternalTabDragConfigurationProvider.value)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension View {
    func internalOnlyTabDrag() -> some View {
        modifier(InternalTabDragConfigurationModifier())
    }
}
