import CmuxAgentChat
import SwiftUI

/// A navigation container for one Mac-hosted artifact path.
public struct ChatArtifactViewerSheet: View {
    let path: String
    let scope: ChatArtifactViewerScope
    let swipeOrder: ChatArtifactGallerySwipeOrder
    @Environment(\.dismiss) private var dismiss

    /// Creates an artifact viewer that routes files and folders through the
    /// same stat-driven navigation path.
    /// - Parameters:
    ///   - path: Initially selected artifact path.
    ///   - scope: Authorization and navigation context for the artifact.
    ///   - swipeOrder: Visible gallery-file order available for horizontal paging.
    public init(
        path: String,
        scope: ChatArtifactViewerScope = .chat,
        swipeOrder: ChatArtifactGallerySwipeOrder = ChatArtifactGallerySwipeOrder(items: [])
    ) {
        self.path = path
        self.scope = scope
        self.swipeOrder = swipeOrder
    }

    public var body: some View {
        NavigationStack {
            ChatArtifactViewerDestination(
                path: path,
                scope: scope,
                swipeOrder: swipeOrder
            ) {
                dismiss()
            }
        }
    }
}

struct ChatArtifactPathSelection: Identifiable, Equatable {
    let path: String
    var id: String { path }
}
