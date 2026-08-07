public import Foundation
internal import UniformTypeIdentifiers

extension TerminalPasteboardService {
    /// Moves a worker-created image into this service's temporary-file root and assumes ownership.
    ///
    /// The source must be a non-empty regular image file directly inside
    /// `sourceDirectory`. Symlinks, nested paths, non-image extensions, and
    /// files over ``maxClipboardImageSize`` are rejected before the move. The
    /// destination root must also be a real directory rather than a symlink.
    ///
    /// - Parameters:
    ///   - sourceURL: The worker-created image file to adopt.
    ///   - sourceDirectory: The isolated directory the worker was allowed to write.
    /// - Returns: The new owned URL under this service's temporary directory.
    /// - Throws: A Cocoa file error when validation or the move fails.
    public func adoptTemporaryImageFile(
        _ sourceURL: URL,
        from sourceDirectory: URL
    ) throws -> URL {
        let allowedDirectory = sourceDirectory.standardizedFileURL
        let source = sourceURL.standardizedFileURL
        guard allowedDirectory.isFileURL,
              source.isFileURL,
              source.deletingLastPathComponent() == allowedDirectory else {
            throw CocoaError(.fileReadInvalidFileName)
        }

        let directoryValues = try allowedDirectory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true else {
            throw CocoaError(.fileReadInvalidFileName)
        }

        let destinationDirectory = temporaryDirectory.standardizedFileURL
        let destinationDirectoryValues = try destinationDirectory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard destinationDirectory.isFileURL,
              destinationDirectoryValues.isDirectory == true,
              destinationDirectoryValues.isSymbolicLink != true else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        let sourceValues = try source.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        guard let fileSize = sourceValues.fileSize,
              fileSize > 0,
              fileSize <= Self.maxClipboardImageSize else {
            throw CocoaError(.fileReadTooLarge)
        }

        let fileExtension = source.pathExtension.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalizedExtension = fileExtension.lowercased()
        guard !normalizedExtension.isEmpty,
              normalizedExtension.utf8.count <= 16,
              normalizedExtension.utf8.allSatisfy({ byte in
                (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                    || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
              }),
              let type = UTType(filenameExtension: normalizedExtension),
              type.conforms(to: .image) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let destination = temporaryImageFileURL(
            fileExtension: normalizedExtension
        ).standardizedFileURL
        guard destination.deletingLastPathComponent() == destinationDirectory else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        do {
            try fileManager.moveItem(at: source, to: destination)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        registerOwnedTemporaryImageFile(destination)
        return destination
    }
}
