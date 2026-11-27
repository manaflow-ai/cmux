/// Enforces the rendered-Markdown size threshold and selected mode.
struct ChatArtifactMarkdownPresentation: Equatable, Sendable {
    static let maximumRenderedByteCount: Int64 = 1_500_000

    let isRenderedAvailable: Bool
    private(set) var mode: ChatArtifactMarkdownMode

    init(byteCount: Int64) {
        isRenderedAvailable = byteCount <= Self.maximumRenderedByteCount
        mode = isRenderedAvailable ? .rendered : .raw
    }

    mutating func select(_ requestedMode: ChatArtifactMarkdownMode) {
        if requestedMode == .rendered, !isRenderedAvailable {
            mode = .raw
        } else {
            mode = requestedMode
        }
    }
}
