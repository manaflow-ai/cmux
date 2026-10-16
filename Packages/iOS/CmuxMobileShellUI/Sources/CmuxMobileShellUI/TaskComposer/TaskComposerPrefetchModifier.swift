import CmuxMobileShell
import SwiftUI

/// Keeps connection observations out of the root view's rendering dependencies.
struct TaskComposerPrefetchModifier: ViewModifier {
    let store: CMUXMobileShellStore

    func body(content: Content) -> some View {
        content
            // Keep the observation in a leaf view. Reading the target list
            // from this modifier body would make every connection update a
            // dependency of the entire workspace shell.
            .background(TaskComposerPrefetchObserver(store: store))
    }
}
