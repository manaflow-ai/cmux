import AppKit

/// A bundled public-domain painting available behind the window material.
/// Game art is never part of this catalog.
public enum BackdropArt: String, Sendable {
    /// Vincent van Gogh's 1889 painting from the Met Open Access collection.
    case wheatField = "wheat-field-with-cypresses"

    /// The museum's canonical attribution, kept in its original form.
    public var attribution: String {
        "Wheat Field with Cypresses · Vincent van Gogh · 1889 · The Metropolitan Museum of Art · CC0"
    }

    /// The museum's artwork page, including the Open Access designation.
    public var sourceURL: URL {
        URL(string: "https://www.metmuseum.org/art/collection/search/436535")!
    }

    /// Loads the packaged image. A missing resource safely paints no art.
    /// - Returns: The painting image, or nil if the bundle is incomplete.
    @MainActor public func image() -> NSImage? {
        guard let url = Bundle.module.url(forResource: rawValue, withExtension: "jpg") else { return nil }
        return NSImage(contentsOf: url)
    }
}
