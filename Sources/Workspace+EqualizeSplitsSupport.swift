extension Workspace {
    func didProgrammaticallyChangeSplitGeometry() {
        splitTabBar(bonsplitController, didChangeGeometry: bonsplitController.layoutSnapshot())
    }
}
