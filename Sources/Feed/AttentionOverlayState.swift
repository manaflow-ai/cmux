@MainActor
final class AttentionOverlayState {
    var count: Int
    var workspace: Workspace

    init(workspace: Workspace) {
        self.count = 0
        self.workspace = workspace
    }
}
