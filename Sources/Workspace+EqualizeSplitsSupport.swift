extension Workspace {
    func didProgrammaticallyChangeSplitGeometry() {
        splitTabBar(layoutController, didChangeGeometry: layoutController.layoutSnapshot())
    }
}
