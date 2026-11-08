extension BrowserViewportLayout {
    /// How the WebView derives its logical viewport.
    public enum Mode: String, Equatable, Sendable {
        /// The logical viewport follows the native pane geometry.
        case native

        /// The requested logical viewport is aspect-fitted inside the pane.
        case emulated
    }
}
