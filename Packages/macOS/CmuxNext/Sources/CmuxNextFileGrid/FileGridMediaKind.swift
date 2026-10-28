public import Foundation
import UniformTypeIdentifiers

/// What a file in a ``FileGridView`` shows as: a picture, a movie with a
/// poster frame and duration, or any other file (its system icon).
public nonisolated enum FileGridMediaKind: String, Sendable, Hashable, CaseIterable {
    /// A still image (PNG, JPEG, HEIC, GIF, TIFF, PDF pages are `other`).
    case image
    /// A movie (MOV, MP4, M4V, WebM when the system knows it).
    case video
    /// Anything else.
    case other

    /// The kind of the file at `url`, from its file name extension alone (no disk read).
    ///
    /// - Parameter url: a file URL; only its path extension is read.
    public init(url: URL) {
        self.init(pathExtension: url.pathExtension)
    }

    /// The kind of a file with this extension (`png`, `mov`; case-insensitive).
    ///
    /// - Parameter pathExtension: the extension without its dot.
    public init(pathExtension: String) {
        guard !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension.lowercased()) else {
            self = .other
            return
        }
        if type.conforms(to: .image) {
            self = .image
        } else if type.conforms(to: .movie) || type.conforms(to: .video) {
            self = .video
        } else {
            self = .other
        }
    }
}
