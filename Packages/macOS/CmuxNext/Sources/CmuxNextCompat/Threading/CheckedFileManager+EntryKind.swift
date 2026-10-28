public import Foundation

extension CheckedFileManager {
    /// What is at `path`, a final symlink followed; nil when nothing is. Like
    /// ``Foundation/FileManager/entryKind(atPath:)``, checked: the pointer-free form of
    /// ``fileExists(atPath:isDirectory:fileID:line:)``.
    ///
    /// - Parameters:
    ///   - path: The path to look at.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: The kind of what exists there, or nil.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func entryKind(atPath path: String, fileID: StaticString = #fileID, line: UInt = #line) -> FileEntryKind? {
        return blockingCall(.fileIO, fileID: fileID, line: line) { FileManager.default.entryKind(atPath: path) }
    }
}
