import Foundation

/// FileManager is documented as safe for concurrent use; the worker further
/// serializes every operation, so this wrapper is the one audited crossing
/// from the main actor into the deletion actor.
struct CEFRuntimeSendableFileManager: @unchecked Sendable {
    let value: FileManager
}

/// Serializes profile-cache removal away from the CEF/main actor.
///
/// CEF's idle check must happen on its UI thread, but recursive directory
/// removal can take an unbounded amount of wall time. A dedicated actor keeps
/// this lifecycle-owned operation off the main actor and serializes deletions
/// so concurrent requests cannot compete for the same profile files.
actor CEFRuntimeProfileDataDeletionWorker {
    private let fileManager: CEFRuntimeSendableFileManager

    init(fileManager: CEFRuntimeSendableFileManager) {
        self.fileManager = fileManager
    }

    func removeIfExists(atPath path: String) -> Bool {
        do {
            try fileManager.value.removeItem(atPath: path)
            return true
        } catch CocoaError.fileNoSuchFile {
            return true
        } catch {
            return false
        }
    }
}
