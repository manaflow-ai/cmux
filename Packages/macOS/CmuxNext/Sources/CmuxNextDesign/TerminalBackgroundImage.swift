public import Foundation

/// The Ghostty config's `background-image` as the terminals draw it: the file, and how much of an
/// opaque pixel of it shows over the background (`background-image-opacity * background-opacity`,
/// as Ghostty draws it, `GhosttyRuntimeSurfacePolicy`). The iPhone shows it as this Mac's wallpaper
/// when no cmux background is chosen (ask-87d30da8e5).
public nonisolated struct TerminalBackgroundImage: Equatable, Sendable {
    /// The picture file, its path expanded.
    public var url: URL
    /// The alpha an opaque pixel of the picture shows at, 0...1.
    public var opacity: Double

    public init(url: URL, opacity: Double) {
        self.url = url
        self.opacity = min(max(opacity, 0), 1)
    }
}
