public import Foundation
internal import Darwin
internal import UniformTypeIdentifiers

extension TerminalPasteboardService {
    private enum TransientImageCopyError: Error {
        case emptySource
        case exceedsSizeLimit
    }

    private static let transientImageCopyChunkSize = 64 * 1024

    /// Rehomes temporary image URLs before a terminal receives their path.
    ///
    /// Returns `nil` when a qualifying transient image cannot be copied. A
    /// failed copy rejects the complete transfer so a multi-file drop cannot
    /// silently omit one of the user's selected files.
    ///
    /// - Parameters:
    ///   - fileURLs: URLs read from a pasteboard or drag provider.
    ///   - sourceIsTransient: Whether the provider promised temporary files.
    /// - Returns: The original URLs plus owned copies, or `nil` on failure.
    public func durableDroppedFileURLs(
        _ fileURLs: [URL],
        sourceIsTransient: Bool = false
    ) -> [URL]? {
        var durableURLs: [URL] = []
        durableURLs.reserveCapacity(fileURLs.count)
        var newlyOwnedURLs: [URL] = []

        for fileURL in fileURLs {
            guard isTransientImageFileURL(
                fileURL,
                sourceIsTransient: sourceIsTransient
            ) else {
                durableURLs.append(fileURL)
                continue
            }

            let wasAlreadyOwned = isOwnedTemporaryImageFile(fileURL)
            guard let durableURL = copyTemporaryImageFile(fileURL) else {
                cleanupTransferredTemporaryImageFiles(newlyOwnedURLs)
                return nil
            }
            durableURLs.append(durableURL)
            if !wasAlreadyOwned {
                newlyOwnedURLs.append(durableURL)
            }
        }

        return durableURLs
    }

    /// Copies a source-owned temporary image into this service's owned storage.
    ///
    /// The source is opened once with symlink-following disabled, validated via
    /// its opened descriptor, and copied through a bounded read loop. This
    /// keeps a drag provider from replacing or growing the path after a
    /// path-based metadata check.
    ///
    /// - Parameter sourceURL: A local regular image file to retain.
    /// - Returns: An owned copy, or `nil` when the source is unavailable,
    ///   invalid, or exceeds the clipboard image-size limit.
    public func copyTemporaryImageFile(_ sourceURL: URL) -> URL? {
        let source = sourceURL.standardizedFileURL
        guard source.isFileURL,
              let type = UTType(filenameExtension: source.pathExtension),
              type.conforms(to: .image),
              isValidTemporaryDirectory else {
            return nil
        }
        if isOwnedTemporaryImageFile(source) {
            return fileManager.fileExists(atPath: source.path) ? source : nil
        }

        let sourceDescriptor = Darwin.open(
            source.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard sourceDescriptor >= 0 else { return nil }
        let sourceHandle = FileHandle(
            fileDescriptor: sourceDescriptor,
            closeOnDealloc: true
        )
        defer { try? sourceHandle.close() }

        var metadata = Darwin.stat()
        guard Darwin.fstat(sourceDescriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_size > 0,
              metadata.st_size <= off_t(Self.maximumImageDataByteCount) else {
            return nil
        }

        let destination = temporaryImageFileURL(
            fileExtension: sanitizedImageFileExtension(
                type.preferredFilenameExtension ?? source.pathExtension
            )
        ).standardizedFileURL
        let destinationDescriptor = Darwin.open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            mode_t(0o600)
        )
        guard destinationDescriptor >= 0 else { return nil }
        let destinationHandle = FileHandle(
            fileDescriptor: destinationDescriptor,
            closeOnDealloc: true
        )
        defer { try? destinationHandle.close() }

        do {
            var copiedByteCount = 0
            while let chunk = try sourceHandle.read(
                upToCount: Self.transientImageCopyChunkSize
            ), !chunk.isEmpty {
                copiedByteCount += chunk.count
                guard copiedByteCount <= Self.maximumImageDataByteCount else {
                    throw TransientImageCopyError.exceedsSizeLimit
                }
                try destinationHandle.write(contentsOf: chunk)
            }
            guard copiedByteCount > 0 else {
                throw TransientImageCopyError.emptySource
            }
            try destinationHandle.close()
        } catch {
            try? destinationHandle.close()
            try? fileManager.removeItem(at: destination)
            return nil
        }

        registerOwnedTemporaryImageFile(destination)
        return destination
    }

    private var isValidTemporaryDirectory: Bool {
        guard let values = try? temporaryDirectory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func isTransientImageFileURL(
        _ fileURL: URL,
        sourceIsTransient: Bool
    ) -> Bool {
        let normalizedURL = fileURL.standardizedFileURL
        guard normalizedURL.isFileURL,
              let type = UTType(filenameExtension: normalizedURL.pathExtension),
              type.conforms(to: .image) else {
            return false
        }

        let path = Self.normalizedTemporaryAlias(normalizedURL.path)
        let temporaryRoots = [
            temporaryDirectory.standardizedFileURL.path,
            fileManager.temporaryDirectory.standardizedFileURL.path,
            "/tmp",
            "/private/tmp",
        ].map(Self.normalizedTemporaryAlias)
        guard temporaryRoots.contains(where: { root in
            path == root || path.hasPrefix(root + "/")
        }) else {
            return false
        }

        let filename = normalizedURL.lastPathComponent.lowercased()
        return sourceIsTransient || filename.hasPrefix("cmux-drop-")
    }

    private static func normalizedTemporaryAlias(_ path: String) -> String {
        if path == "/tmp" || path.hasPrefix("/tmp/") {
            return "/private" + path
        }
        if path == "/var" || path.hasPrefix("/var/") {
            return "/private" + path
        }
        return path
    }
}
