import CmuxAgentChat
import SwiftUI

public extension ChatArtifactGalleryGlyphTint {
    /// SwiftUI color corresponding to the shared gallery tint.
    var swiftUIColor: Color {
        switch self {
        case .accent:
            return .blue
        case .secondary:
            return .secondary
        }
    }
}
