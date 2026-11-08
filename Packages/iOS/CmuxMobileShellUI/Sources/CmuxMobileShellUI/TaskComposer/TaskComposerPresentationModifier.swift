#if os(iOS)
import SwiftUI

private struct TaskComposerPresentationModifier<PresentedContent: View>: ViewModifier {
    @Binding private var isPresented: Bool
    private let onDismiss: () -> Void
    private let presentedContent: (
        TaskComposerLaunch,
        _ switchDraft: @escaping (TaskComposerLaunchIntent) -> Void
    ) -> PresentedContent

    /// The current editing session inside one presentation. Draft switches
    /// replace it, which recreates the sheet through `.id(launch.token)` so
    /// the selected draft passes the init's full restore validation.
    @State private var launch = TaskComposerLaunch()

    init(
        isPresented: Binding<Bool>,
        onDismiss: @escaping () -> Void,
        @ViewBuilder presentedContent: @escaping (
            TaskComposerLaunch,
            _ switchDraft: @escaping (TaskComposerLaunchIntent) -> Void
        ) -> PresentedContent
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
            onDismiss: {
                // The next presentation starts a fresh session (drafts load
                // only from the drafts list), and it must get a brand-new
                // view identity: reusing the token would let @State (draft
                // identity, persist flags, dirty baseline) leak from the
                // closed session.
                launch = TaskComposerLaunch(token: launch.token + 1)
                onDismiss()
            },
            content: {
                presentedContent(launch) { intent in
                    launch = launch.switching(to: intent)
                }
                .id(launch.token)
            }
        )
    }
}

extension View {
    func taskComposerPresentation<PresentedContent: View>(
        isPresented: Binding<Bool>,
        onDismiss: @escaping () -> Void = {},
        @ViewBuilder content: @escaping (
            TaskComposerLaunch,
            _ switchDraft: @escaping (TaskComposerLaunchIntent) -> Void
        ) -> PresentedContent
    ) -> some View {
        modifier(TaskComposerPresentationModifier(
            isPresented: isPresented,
            onDismiss: onDismiss,
            presentedContent: content
        ))
    }
}
#endif
