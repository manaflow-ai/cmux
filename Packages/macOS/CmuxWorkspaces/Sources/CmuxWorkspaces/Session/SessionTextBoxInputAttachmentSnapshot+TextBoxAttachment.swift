import Foundation

public extension SessionTextBoxInputAttachmentSnapshot {
    /// Rebuilds the live ``TextBoxAttachment`` from this persisted snapshot.
    ///
    /// The value-only half of the draft-attachment bridge: it restores the local
    /// file URL (dropping it when the durable copy no longer exists) and rebuilds
    /// the attachment from the persisted submission fields. The app-coupled half
    /// (capturing a live attachment into a snapshot through the draft store) stays
    /// in an app-target initializer.
    func textBoxAttachment() -> TextBoxAttachment {
        let restoredLocalURL: URL?
        if let localPath {
            let url = URL(fileURLWithPath: localPath).standardizedFileURL
            restoredLocalURL = FileManager.default.fileExists(atPath: url.path) ? url : nil
        } else {
            restoredLocalURL = nil
        }
        return TextBoxAttachment(
            displayName: displayName,
            submissionText: submissionText,
            submissionPath: submissionPath,
            localURL: restoredLocalURL,
            cleanupLocalURLWhenDisposed: cleanupLocalPathWhenDisposed
        )
    }
}
