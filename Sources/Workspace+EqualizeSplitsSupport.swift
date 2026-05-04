extension Workspace {
    func didProgrammaticallyChangeSplitGeometry() {
        tmuxLayoutSnapshot = bonsplitController.layoutSnapshot()
        scheduleTerminalGeometryReconcile()
    }
}
