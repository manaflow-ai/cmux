package import Foundation

/// A file as a page gets it: the bytes decoded as UTF-8 with nothing removed (a BOM stays as
/// U+FEFF, every line ending stays), so writing the page's text back as UTF-8 reproduces the bytes.
nonisolated package struct FileSnapshot: Sendable, Equatable {
    /// The file's real path (links resolved).
    package let url: URL
    package let text: String
    /// SHA-256 of the bytes, lowercase hex.
    package let hash: String
    package let size: Int
    package let readOnlyReason: FileReadOnlyReason?

    package init(url: URL, text: String, hash: String, size: Int, readOnlyReason: FileReadOnlyReason?) {
        self.url = url
        self.text = text
        self.hash = hash
        self.size = size
        self.readOnlyReason = readOnlyReason
    }
}
