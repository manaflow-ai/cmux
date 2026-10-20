import CmuxAgentChat
import SwiftUI

/// The shared inline navigation destination for a Mac-hosted artifact path.
public struct ChatArtifactViewerDestination: View {
    private let path: String
    private let scope: ChatArtifactViewerScope
    private let swipeOrder: ChatArtifactGallerySwipeOrder
    private let onDone: () -> Void

    /// Creates an inline artifact viewer for an existing navigation stack.
    ///
    /// - Parameters:
    ///   - path: Initially selected artifact path.
    ///   - scope: Authorization and navigation context for the artifact.
    ///   - swipeOrder: Visible gallery-file order available for horizontal paging.
    ///   - onDone: Dismisses or pops the navigation container that owns the destination.
    public init(
        path: String,
        scope: ChatArtifactViewerScope = .chat,
        swipeOrder: ChatArtifactGallerySwipeOrder = ChatArtifactGallerySwipeOrder(items: []),
        onDone: @escaping () -> Void
    ) {
        self.path = path
        self.scope = scope
        self.swipeOrder = swipeOrder
        self.onDone = onDone
    }

    public var body: some View {
        ChatArtifactViewerPager(
            initialPath: path,
            scope: scope,
            swipeOrder: swipeOrder,
            onDone: onDone
        )
    }
}
