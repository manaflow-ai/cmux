import Foundation

/// A temporary, self-cleaning copy of the Hermes SQLite database and sidecars.
struct HermesAgentDatabaseSnapshot {
    let databaseURL: URL
    private let directoryURL: URL
    private let fileManager: FileManager

    init(databaseURL: URL, directoryURL: URL, fileManager: FileManager) {
        self.databaseURL = databaseURL
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    func remove() {
        try? fileManager.removeItem(at: directoryURL)
    }
}
