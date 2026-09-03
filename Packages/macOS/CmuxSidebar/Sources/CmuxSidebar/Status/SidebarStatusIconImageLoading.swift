public import CoreGraphics

/// Loads validated local images for sidebar status entries.
public protocol SidebarStatusIconImageLoading: Sendable {
    /// Loads and decodes the image at an absolute path or a path beginning with `~`.
    ///
    /// - Parameter rawPath: The local image path from an `image:` status icon token.
    /// - Returns: A decoded image, or `nil` when the path or image is invalid.
    func image(at rawPath: String) async -> CGImage?
}
