import SwiftUI

/// A navigation container for one Mac-hosted artifact path.
public struct ChatArtifactViewerSheet: View {
    let path: String
    let scope: ChatArtifactViewerScope
    @Environment(\.dismiss) private var dismiss

    /// Creates an artifact viewer that routes files and folders through the
    /// same stat-driven navigation path.
    public init(path: String, scope: ChatArtifactViewerScope = .chat) {
        self.path = path
        self.scope = scope
    }

    public var body: some View {
        NavigationStack {
            ChatArtifactViewerRouteView(path: path, scope: scope) {
                dismiss()
            }
        }
    }
}

struct ChatArtifactPathSelection: Identifiable, Equatable {
    let path: String
    var id: String { path }
}
