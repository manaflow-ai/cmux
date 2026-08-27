import Foundation

/// A file manager that leaves removal targets intact so cleanup uses can be observed.
final class NonDeletingFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {}
}
