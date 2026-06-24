#if os(iOS)
import SwiftUI

/// Moves the chat transcript/composer stack with the software keyboard.
///
/// SwiftUI's default keyboard avoidance can translate a focused field without
/// changing the embedded `UITableView`'s frame. This modifier hosts the chat
/// root in UIKit and animates the hosted view's bottom constraint from
/// `UIKeyboardWillChangeFrame`, so the transcript's actual bounds shrink while
/// the composer rides the keyboard edge.
struct ChatKeyboardTrackingLayout: ViewModifier {
    func body(content: Content) -> some View {
        ChatKeyboardTrackingContainer(content: content)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}
#endif
