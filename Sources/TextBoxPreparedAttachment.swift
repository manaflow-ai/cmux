import Foundation

/// Immutable composer attachment data produced before returning to the main actor.
struct TextBoxPreparedAttachment: Equatable, Sendable {
    let fileURL: URL
    let thumbnailPNGData: Data?

    init(fileURL: URL, thumbnailPNGData: Data?) {
        self.fileURL = fileURL.standardizedFileURL
        self.thumbnailPNGData = thumbnailPNGData
    }
}
