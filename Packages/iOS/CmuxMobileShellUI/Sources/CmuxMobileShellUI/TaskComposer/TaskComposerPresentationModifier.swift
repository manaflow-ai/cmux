#if os(iOS)
import SwiftUI

private struct TaskComposerPresentationModifier<PresentedContent: View>: ViewModifier {
    @Binding private var isPresented: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private let presentedContent: () -> PresentedContent

    init(
        isPresented: Binding<Bool>,
        @ViewBuilder presentedContent: @escaping () -> PresentedContent
    ) {
        _isPresented = isPresented
        self.presentedContent = presentedContent
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if horizontalSizeClass == .regular {
            // A regular-width form sheet ends above the docked iPad keyboard,
            // so its bottom controls cannot be keyboard-pinned. Give the
            // canonical composer the full screen in that presentation class.
            content.fullScreenCover(
                isPresented: $isPresented,
                content: presentedContent
            )
        } else {
            content.sheet(
                isPresented: $isPresented,
                content: presentedContent
            )
        }
    }
}

extension View {
    func taskComposerPresentation<PresentedContent: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> PresentedContent
    ) -> some View {
        modifier(TaskComposerPresentationModifier(
            isPresented: isPresented,
            presentedContent: content
        ))
    }
}
#endif
