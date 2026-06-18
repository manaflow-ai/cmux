import SwiftUI

/// Resolved maximum bubble width (container width times the theme's
/// fraction), measured once at the transcript-list level so rows never
/// need their own GeometryReader.
struct ChatBubbleMaxWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = .infinity
}

extension EnvironmentValues {
    /// The maximum width a chat bubble may occupy.
    var chatBubbleMaxWidth: CGFloat {
        get { self[ChatBubbleMaxWidthKey.self] }
        set { self[ChatBubbleMaxWidthKey.self] = newValue }
    }
}
