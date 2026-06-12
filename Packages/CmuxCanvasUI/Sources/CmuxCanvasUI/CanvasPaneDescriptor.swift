public import AppKit

/// A value snapshot describing one pane the canvas should display.
///
/// Built by the host's SwiftUI container on every update pass; the canvas
/// root view diffs descriptors against its current pane views, so host state
/// changes flow into AppKit without the canvas observing any store.
@MainActor
public struct CanvasPaneDescriptor: Identifiable {
    public let id: UUID
    public let chrome: CanvasPaneChrome
    /// Mounts the panel's content into the pane's content container and
    /// returns the lifecycle handle. Called once per mount.
    public let makeMount: (NSView) -> any CanvasPaneContentMounting

    public init(
        id: UUID,
        chrome: CanvasPaneChrome,
        makeMount: @escaping (NSView) -> any CanvasPaneContentMounting
    ) {
        self.id = id
        self.chrome = chrome
        self.makeMount = makeMount
    }
}
