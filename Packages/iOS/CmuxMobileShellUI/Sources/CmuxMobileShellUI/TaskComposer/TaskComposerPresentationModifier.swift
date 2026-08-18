#if os(iOS)
import SwiftUI

private struct TaskComposerPresentationModifier<PresentedContent: View>: ViewModifier {
    @Binding private var isPresented: Bool
    private let onDismiss: () -> Void
    private let presentedContent: () -> PresentedContent

    init(
        isPresented: Binding<Bool>,
        onDismiss: @escaping () -> Void,
        @ViewBuilder presentedContent: @escaping () -> PresentedContent
    ) {
        _isPresented = isPresented
        self.onDismiss = onDismiss
        self.presentedContent = presentedContent
    }

    func body(content: Content) -> some View {
        // One presenter owns the whole editing session. Switching between a
        // sheet and a full-screen cover during Split View resizing tears down
        // the draft, focus, and staged attachments.
        content.fullScreenCover(
            isPresented: $isPresented,
            onDismiss: onDismiss,
            content: presentedContent
        )
    }
}

extension View {
    func taskComposerPresentation<PresentedContent: View>(
        isPresented: Binding<Bool>,
        onDismiss: @escaping () -> Void = {},
        @ViewBuilder content: @escaping () -> PresentedContent
    ) -> some View {
        modifier(TaskComposerPresentationModifier(
            isPresented: isPresented,
            onDismiss: onDismiss,
            presentedContent: content
        ))
    }
}
#endif
