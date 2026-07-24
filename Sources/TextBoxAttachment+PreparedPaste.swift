import AppKit
import Foundation

extension TextBoxAttachment {
    /// Creates an attachment without reopening the full-resolution source image on the main actor.
    init(
        preparedAttachment: TextBoxPreparedAttachment,
        submissionText: String,
        submissionPath: String? = nil,
        cleanupLocalURLWhenDisposed: Bool = false
    ) {
        let standardizedURL = preparedAttachment.fileURL.standardizedFileURL
        self.displayName = standardizedURL.lastPathComponent.isEmpty
            ? standardizedURL.path
            : standardizedURL.lastPathComponent
        self.submissionText = submissionText
        self.submissionPath = submissionPath ?? standardizedURL.path
        self.localURL = standardizedURL
        self.thumbnail = preparedAttachment.thumbnailPNGData.flatMap(NSImage.init(data:))
        self.cleanupLocalURLWhenDisposed = cleanupLocalURLWhenDisposed
    }
}
