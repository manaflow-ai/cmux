extension AgentPaneView {
    /// The script that tells a loaded page whether preview features show.
    static func previewScript(_ on: Bool) -> String {
        "window.cmuxAcpmuxBridge?.applyPreview?.(\(on));"
    }

    /// Pushes ``previewFeatures`` to the page.
    func applyPreviewFeatures() {
        deliver([.preview(previewFeatures)], scripts: [Self.previewScript(previewFeatures)])
    }
}
