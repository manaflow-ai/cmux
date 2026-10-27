extension AgentPaneView {
    /// Pushes ``previewFeatures`` to the page.
    func applyPreviewFeatures() {
        deliver([.preview(previewFeatures)])
    }
}
