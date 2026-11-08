/// Applies pending workspace move intents to a local workspace snapshot.
struct MobileWorkspaceOrderMoveApplier {
    let workspaces: [MobileWorkspacePreview]
    let groups: [MobileWorkspaceGroupPreview]

    func applying(
        _ intent: MobileWorkspaceMoveIntent,
        movedWorkspaceID: MobileWorkspacePreview.ID
    ) -> [MobileWorkspacePreview] {
        MobileWorkspaceMovePolicy(workspaces: workspaces, groups: groups)
            .applyingHostMove(intent, movedWorkspaceID: movedWorkspaceID)
    }
}
