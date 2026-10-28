public import AppKit
public import CmuxNextAppearance

/// A bundled work's image files: the full image ships in CmuxNextDesign's resources or downloads into
/// the backgrounds folder (``BackdropArtDownloads``); every work ships its thumbnail.
public nonisolated extension BackdropArt {
    /// The full image: bundled, or downloaded earlier into the backgrounds folder; nil until then.
    var imageURL: URL? {
        if isBundled { return Bundle.module.url(forResource: rawValue, withExtension: "avif") }
        return BackdropArtDownloads.shared.cachedFile(id: rawValue)
    }

    /// The 480×300 thumbnail every work ships with.
    var thumbnailURL: URL? {
        Bundle.module.url(forResource: "\(rawValue).thumb", withExtension: "avif")
    }

    /// The full image if it is here yet, else the thumbnail. A missing resource paints no art.
    @MainActor func image() -> NSImage? {
        (imageURL ?? thumbnailURL).flatMap(NSImage.init(contentsOf:))
    }
}
