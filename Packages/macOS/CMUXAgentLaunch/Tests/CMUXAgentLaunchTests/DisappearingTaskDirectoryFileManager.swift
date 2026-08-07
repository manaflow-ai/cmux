import Foundation
@testable import CMUXAgentLaunch

/// Removes one task directory immediately before its first enumeration.
final class DisappearingTaskDirectoryFileManager: ClaudeTaskFileSystem {
    let disappearingDirectoryURL: URL
    private let fileManager = FileManager.default
    private let deletesAfterEnumeration: Bool
    private var didRemoveDirectory = false
    private var directoryValidationCount = 0

    init(
        disappearingDirectoryURL: URL,
        deletesAfterEnumeration: Bool = false
    ) {
        self.disappearingDirectoryURL = disappearingDirectoryURL
            .canonicalClaudeTaskStoreDirectoryURL
        self.deletesAfterEnumeration = deletesAfterEnumeration
    }

    func fileExists(
        atPath path: String,
        isDirectory: UnsafeMutablePointer<ObjCBool>?
    ) -> Bool {
        fileManager.fileExists(atPath: path, isDirectory: isDirectory)
    }

    func enumerator(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = [],
        errorHandler handler: ((URL, any Error) -> Bool)? = nil
    ) -> FileManager.DirectoryEnumerator? {
        if !deletesAfterEnumeration,
           url == disappearingDirectoryURL,
           !didRemoveDirectory {
            didRemoveDirectory = true
            try? fileManager.removeItem(at: url)
            return nil
        }
        return fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: mask,
            errorHandler: handler
        )
    }

    func resourceValues(
        for url: URL,
        keys: Set<URLResourceKey>
    ) throws -> URLResourceValues {
        if deletesAfterEnumeration,
           url == disappearingDirectoryURL,
           keys.contains(.isDirectoryKey) {
            directoryValidationCount += 1
            if directoryValidationCount == 2, !didRemoveDirectory {
                didRemoveDirectory = true
                try fileManager.removeItem(at: url)
            }
        }
        return try url.resourceValues(forKeys: keys)
    }
}
