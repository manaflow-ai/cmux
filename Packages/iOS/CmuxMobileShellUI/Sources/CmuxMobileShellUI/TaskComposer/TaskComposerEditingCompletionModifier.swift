#if os(iOS)
import SwiftUI

/// Routes submit and focus-loss events through one editing-completion path.
private struct TaskComposerEditingCompletionModifier: ViewModifier {
    let isFocused: Bool
    let endEditing: () -> Void

    func body(content: Content) -> some View {
        content
            .onSubmit(endEditing)
            .onChange(of: isFocused) { wasFocused, isFocused in
                if wasFocused && !isFocused {
                    endEditing()
                }
            }
    }
}

extension View {
    /// Finishes task-composer editing after submit or focus loss.
    func taskComposerEditingCompletion(
        isFocused: Bool,
        endEditing: @escaping () -> Void
    ) -> some View {
        modifier(TaskComposerEditingCompletionModifier(
            isFocused: isFocused,
            endEditing: endEditing
        ))
    }
}
#endif
