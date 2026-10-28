public import Foundation

/// What `FileManager.fileExists(atPath:isDirectory:)` finds at a path, a final symlink followed.
public enum FileEntryKind: Equatable, Sendable {
    /// A folder, or a symlink to one.
    case directory
    /// Anything else that exists: a file, a socket, a symlink to one.
    case nonDirectory
}

extension FileManager {
    /// What is at `path`, a final symlink followed; nil when nothing is. The one place that passes
    /// `fileExists(atPath:isDirectory:)` its flag pointer, so callers stay pointer-free (strict
    /// memory safety).
    ///
    /// - Parameter path: The path to look at.
    /// - Returns: The kind of what exists there, or nil.
    public func entryKind(atPath path: String) -> FileEntryKind? {
        var directory: ObjCBool = false
        // SAFETY: `directory` is a local that outlives the call; Foundation writes one ObjCBool
        // through the pointer and keeps no reference to it after returning.
        guard unsafe fileExists(atPath: path, isDirectory: &directory) else { return nil }
        return directory.boolValue ? .directory : .nonDirectory
    }

    /// Whether `path` names a folder (or a symlink to one).
    ///
    /// - Parameter path: The path to look at.
    /// - Returns: True for a folder.
    public func directoryExists(atPath path: String) -> Bool {
        entryKind(atPath: path) == .directory
    }
}

extension CheckedFileManager {
    /// Whether `path` names a folder (or a symlink to one). Like ``Foundation/FileManager/directoryExists(atPath:)``,
    /// checked.
    ///
    /// - Parameters:
    ///   - path: The path to look at.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: True for a folder.
    public func directoryExists(atPath path: String, fileID: StaticString = #fileID, line: UInt = #line) -> Bool {
        blockingCall(.fileIO, fileID: fileID, line: line) { FileManager.default.directoryExists(atPath: path) }
    }
}
