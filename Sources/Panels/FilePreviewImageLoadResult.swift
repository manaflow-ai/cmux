import AppKit

/// Immutable ownership transfer from the background decoder to the main actor.
struct FilePreviewImageLoadResult: @unchecked Sendable {
    let image: NSImage?

    init(url: URL) {
        image = NSImage(contentsOf: url)
    }

    @concurrent
    static func load(url: URL) async -> FilePreviewImageLoadResult {
        FilePreviewImageLoadResult(url: url)
    }
}
