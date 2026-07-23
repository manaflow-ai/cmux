import Foundation

/// Reference-counted Feed attention owned by the workspace that was mutated.
@MainActor
final class FeedAttentionOverlayState {
    var count = 0
    var workspace: Workspace

    init(workspace: Workspace) {
        self.workspace = workspace
    }
}
