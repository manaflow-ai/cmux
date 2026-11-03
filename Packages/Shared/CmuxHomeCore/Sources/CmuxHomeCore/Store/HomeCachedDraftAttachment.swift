public import Foundation

/// A picture or file left in a compose field: its ref and its files in the
/// client blob cache, so the chip comes back after a relaunch with the text.
public struct HomeCachedDraftAttachment: Hashable, Sendable, Codable {
    public var ref: AttachmentRef
    public var fileURL: URL
    public var posterURL: URL?
    public var previewURL: URL?

    public init(_ attachment: LocalAttachment) {
        ref = attachment.ref
        fileURL = attachment.fileURL
        posterURL = attachment.posterURL
        previewURL = attachment.previewURL
    }

    /// Its file, poster and preview, whichever it has.
    var urls: [URL] { [fileURL, posterURL, previewURL].compactMap { $0 } }

    /// The prepared attachment again; nil once the blob cache no longer holds
    /// its bytes, its poster or its preview (a send needs all three).
    var local: LocalAttachment? {
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        return LocalAttachment(ref: ref, fileURL: fileURL, posterURL: posterURL, previewURL: previewURL)
    }
}

