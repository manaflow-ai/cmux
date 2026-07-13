import Darwin
import Foundation

/// Copies selected worktree paths with aggregate item, byte, disk, and cancellation guards.
struct WorktreeIncludeCopyService: Sendable {
    private static let resourceKeys: Set<URLResourceKey> = [
        .fileSizeKey,
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
    ]

    // FileManager operations used here are documented thread-safe, and this
    // immutable injected instance has no delegate or mutable caller-owned state.
    private nonisolated(unsafe) let fileManager: FileManager
    private let limits: WorktreeIncludeCopyLimits
    private let availableCapacity: @Sendable (URL) -> Int64?
    private let destinationFileCreated: @Sendable (URL) -> Void
    private let sourceItemInspected: @Sendable (URL) -> Void

    init(
        fileManager: FileManager,
        limits: WorktreeIncludeCopyLimits = .production,
        availableCapacity: @escaping @Sendable (URL) -> Int64? = { destination in
            if let capacity = try? destination.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ).volumeAvailableCapacityForImportantUsage {
                return capacity
            }
            let attributes = try? FileManager.default.attributesOfFileSystem(forPath: destination.path)
            return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
        },
        destinationFileCreated: @escaping @Sendable (URL) -> Void = { _ in },
        sourceItemInspected: @escaping @Sendable (URL) -> Void = { _ in }
    ) {
        self.fileManager = fileManager
        self.limits = limits
        self.availableCapacity = availableCapacity
        self.destinationFileCreated = destinationFileCreated
        self.sourceItemInspected = sourceItemInspected
    }

    func copy(relativePaths: [String], from source: URL, to destination: URL) -> [String] {
        var diagnostics: [String] = []
        var copyablePaths: [String] = []
        var itemCount = 0
        var byteCount: Int64 = 0
        var copiedItemCount = 0
        var copiedByteCount: Int64 = 0
        var createdItems: [WorktreeIncludeCreatedItem] = []

        for relativePath in relativePaths {
            if Task.isCancelled {
                return diagnostics + ["Cancelled .worktreeinclude copy before it completed."]
            }
            let sourceItem = source.appendingPathComponent(relativePath).standardizedFileURL
            do {
                try preflight(sourceItem, itemCount: &itemCount, byteCount: &byteCount)
                copyablePaths.append(relativePath)
            } catch is CancellationError {
                diagnostics.append("Cancelled .worktreeinclude copy before it completed.")
                return diagnostics
            } catch {
                diagnostics.append(
                    "Could not inspect .worktreeinclude path \(relativePath): \(error.localizedDescription)"
                )
            }
            if itemCount > limits.maximumItemCount || byteCount > limits.maximumByteCount {
                diagnostics.append(copyLimitDiagnostic(itemCount: itemCount, byteCount: byteCount))
                return diagnostics
            }
        }

        guard let availableCapacity = availableCapacity(destination) else {
            diagnostics.append(
                "Skipped .worktreeinclude copy because the destination volume's available capacity could not be determined."
            )
            return diagnostics
        }
        guard availableCapacity > limits.freeSpaceReserve else {
            diagnostics.append(
                "Skipped .worktreeinclude copy because the destination volume lacks sufficient free space."
            )
            return diagnostics
        }
        let availableByteBudget = availableCapacity - limits.freeSpaceReserve
        if byteCount > availableByteBudget {
            diagnostics.append(
                "Skipped .worktreeinclude copy because the destination volume lacks sufficient free space."
            )
            return diagnostics
        }

        let destinationRoot: WorktreeIncludeDestinationRoot
        do {
            destinationRoot = try WorktreeIncludeDestinationRoot(rootURL: destination)
        } catch {
            diagnostics.append(
                "Skipped .worktreeinclude copy because the destination root could not be opened safely: \(error.localizedDescription)"
            )
            return diagnostics
        }

        copyLoop: for relativePath in copyablePaths {
            if Task.isCancelled {
                diagnostics.append("Cancelled .worktreeinclude copy before it completed.")
                break copyLoop
            }
            let destinationItem = destination.appendingPathComponent(relativePath).standardizedFileURL
            let destinationRelativePath: String
            do {
                destinationRelativePath = try destinationRoot.relativePath(for: destinationItem)
            } catch {
                diagnostics.append(
                    "Could not copy .worktreeinclude path \(relativePath): \(error.localizedDescription)"
                )
                continue copyLoop
            }
            let createdItemStartIndex = createdItems.count
            do {
                try copyItem(
                    source.appendingPathComponent(relativePath).standardizedFileURL,
                    to: destinationItem,
                    destinationRelativePath: destinationRelativePath,
                    itemCount: &copiedItemCount,
                    byteCount: &copiedByteCount,
                    availableByteBudget: availableByteBudget,
                    destinationRoot: destinationRoot,
                    createdItems: &createdItems
                )
            } catch is CancellationError {
                removeCreatedItems(
                    since: createdItemStartIndex,
                    destinationRoot: destinationRoot,
                    createdItems: &createdItems
                )
                diagnostics.append("Cancelled .worktreeinclude copy before it completed.")
                break copyLoop
            } catch let limitError as WorktreeIncludeCopyLimitError {
                removeCreatedItems(
                    since: createdItemStartIndex,
                    destinationRoot: destinationRoot,
                    createdItems: &createdItems
                )
                diagnostics.append(limitError.localizedDescription)
                break copyLoop
            } catch {
                removeCreatedItems(
                    since: createdItemStartIndex,
                    destinationRoot: destinationRoot,
                    createdItems: &createdItems
                )
                diagnostics.append(
                    "Could not copy .worktreeinclude path \(relativePath): \(error.localizedDescription)"
                )
            }
        }
        for directory in createdItems.reversed() {
            if Task.isCancelled {
                if !diagnostics.contains(where: { $0.localizedCaseInsensitiveContains("cancelled") }) {
                    diagnostics.append("Cancelled .worktreeinclude copy before it completed.")
                }
                break
            }
            guard let source = directory.directoryMetadataSource,
                  (try? destinationRoot.itemExists(at: directory.relativePath)) == true else { continue }
            do {
                try destinationRoot.applySecurityMetadata(
                    from: source,
                    to: directory.relativePath,
                    expectedDevice: directory.device,
                    expectedInode: directory.inode
                )
            } catch {
                diagnostics.append(
                    "Could not preserve .worktreeinclude directory metadata for \(source.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
        return diagnostics
    }

    private func preflight(
        _ sourceItem: URL,
        itemCount: inout Int,
        byteCount: inout Int64
    ) throws {
        let rootValues = try sourceItem.resourceValues(forKeys: Self.resourceKeys)
        account(rootValues, itemCount: &itemCount, byteCount: &byteCount)
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { return }
        guard let enumerator = fileManager.enumerator(atPath: sourceItem.path) else {
            throw CocoaError(.fileReadUnknown)
        }
        while let relativePath = enumerator.nextObject() as? String {
            if Task.isCancelled { throw CancellationError() }
            let child = sourceItem.appendingPathComponent(relativePath)
            let values = try child.resourceValues(forKeys: Self.resourceKeys)
            account(values, itemCount: &itemCount, byteCount: &byteCount)
            if itemCount > limits.maximumItemCount || byteCount > limits.maximumByteCount {
                return
            }
        }
    }

    private func account(
        _ values: URLResourceValues,
        itemCount: inout Int,
        byteCount: inout Int64
    ) {
        itemCount += 1
        if values.isRegularFile == true,
           values.isSymbolicLink != true,
           let size = values.fileSize {
            byteCount += Int64(size)
        }
    }

    private func copyItem(
        _ sourceItem: URL,
        to destinationItem: URL,
        destinationRelativePath: String,
        itemCount: inout Int,
        byteCount: inout Int64,
        availableByteBudget: Int64,
        destinationRoot: WorktreeIncludeDestinationRoot,
        createdItems: inout [WorktreeIncludeCreatedItem]
    ) throws {
        let rootValues = try sourceItem.resourceValues(forKeys: Self.resourceKeys)
        sourceItemInspected(sourceItem)
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            try createDirectoryIfNeeded(
                destinationItem.deletingLastPathComponent(),
                from: sourceItem.deletingLastPathComponent(),
                destinationRoot: destinationRoot,
                itemCount: &itemCount,
                byteCount: byteCount,
                createdItems: &createdItems
            )
            try accountCopiedItem(
                itemCount: &itemCount,
                byteCount: byteCount,
                destinationRoot: destinationRoot
            )
            if rootValues.isRegularFile == true, rootValues.isSymbolicLink != true {
                try copyRegularFile(
                    sourceItem,
                    to: destinationRelativePath,
                    itemCount: itemCount,
                    byteCount: &byteCount,
                    availableByteBudget: availableByteBudget,
                    destinationRoot: destinationRoot,
                    createdItems: &createdItems
                )
            } else if rootValues.isSymbolicLink == true {
                try copySymbolicLink(
                    sourceItem,
                    to: destinationRelativePath,
                    destinationRoot: destinationRoot,
                    createdItems: &createdItems
                )
            } else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            return
        }

        try createDirectoryIfNeeded(
            destinationItem,
            from: sourceItem,
            destinationRoot: destinationRoot,
            itemCount: &itemCount,
            byteCount: byteCount,
            createdItems: &createdItems
        )
        guard let enumerator = fileManager.enumerator(atPath: sourceItem.path) else {
            throw CocoaError(.fileReadUnknown)
        }
        while let relativePath = enumerator.nextObject() as? String {
            if Task.isCancelled { throw CancellationError() }
            let child = sourceItem.appendingPathComponent(relativePath)
            let destinationChild = destinationItem.appendingPathComponent(relativePath)
            let values = try child.resourceValues(forKeys: Self.resourceKeys)
            if values.isDirectory == true, values.isSymbolicLink != true {
                try createDirectoryIfNeeded(
                    destinationChild,
                    from: child,
                    destinationRoot: destinationRoot,
                    itemCount: &itemCount,
                    byteCount: byteCount,
                    createdItems: &createdItems
                )
            } else {
                try createDirectoryIfNeeded(
                    destinationChild.deletingLastPathComponent(),
                    from: child.deletingLastPathComponent(),
                    destinationRoot: destinationRoot,
                    itemCount: &itemCount,
                    byteCount: byteCount,
                    createdItems: &createdItems
                )
                try accountCopiedItem(
                    itemCount: &itemCount,
                    byteCount: byteCount,
                    destinationRoot: destinationRoot
                )
                if values.isRegularFile == true, values.isSymbolicLink != true {
                    let destinationChildRelativePath = try destinationRoot.relativePath(for: destinationChild)
                    try copyRegularFile(
                        child,
                        to: destinationChildRelativePath,
                        itemCount: itemCount,
                        byteCount: &byteCount,
                        availableByteBudget: availableByteBudget,
                        destinationRoot: destinationRoot,
                        createdItems: &createdItems
                    )
                } else if values.isSymbolicLink == true {
                    try copySymbolicLink(
                        child,
                        to: try destinationRoot.relativePath(for: destinationChild),
                        destinationRoot: destinationRoot,
                        createdItems: &createdItems
                    )
                } else {
                    throw CocoaError(.fileReadUnsupportedScheme)
                }
            }
        }
    }

    private func createDirectoryIfNeeded(
        _ destinationDirectory: URL,
        from sourceDirectory: URL,
        destinationRoot: WorktreeIncludeDestinationRoot,
        itemCount: inout Int,
        byteCount: Int64,
        createdItems: inout [WorktreeIncludeCreatedItem]
    ) throws {
        let destinationDirectory = destinationDirectory.standardizedFileURL
        let relativePath = try destinationRoot.relativePath(for: destinationDirectory)
        guard !relativePath.isEmpty,
              try !destinationRoot.directoryExists(at: relativePath) else { return }
        try createDirectoryIfNeeded(
            destinationDirectory.deletingLastPathComponent(),
            from: sourceDirectory.deletingLastPathComponent(),
            destinationRoot: destinationRoot,
            itemCount: &itemCount,
            byteCount: byteCount,
            createdItems: &createdItems
        )
        try accountCopiedItem(
            itemCount: &itemCount,
            byteCount: byteCount,
            destinationRoot: destinationRoot
        )
        let identity = try destinationRoot.createDirectory(at: relativePath, permissions: 0o700)
        createdItems.append(WorktreeIncludeCreatedItem(
            relativePath: relativePath,
            device: identity.device,
            inode: identity.inode,
            isDirectory: true,
            directoryMetadataSource: sourceDirectory
        ))
    }

    private func removeCreatedItems(
        since startIndex: Int,
        destinationRoot: WorktreeIncludeDestinationRoot,
        createdItems: inout [WorktreeIncludeCreatedItem]
    ) {
        guard startIndex < createdItems.count else { return }
        for item in createdItems[startIndex...].reversed() {
            try? destinationRoot.removeItemIfUnchanged(
                at: item.relativePath,
                device: item.device,
                inode: item.inode,
                isDirectory: item.isDirectory
            )
        }
        createdItems.removeSubrange(startIndex...)
    }

    private func accountCopiedItem(
        itemCount: inout Int,
        byteCount: Int64,
        destinationRoot: WorktreeIncludeDestinationRoot
    ) throws {
        itemCount += 1
        guard itemCount <= limits.maximumItemCount else {
            throw WorktreeIncludeCopyLimitError(
                itemCount: itemCount,
                byteCount: byteCount,
                reason: .resourceLimit
            )
        }
        guard let currentCapacity = availableCapacity(destinationRoot.rootURL),
              currentCapacity > limits.freeSpaceReserve else {
            throw WorktreeIncludeCopyLimitError(
                itemCount: itemCount,
                byteCount: byteCount,
                reason: .capacity
            )
        }
    }

    private func copyRegularFile(
        _ sourceItem: URL,
        to destinationRelativePath: String,
        itemCount: Int,
        byteCount: inout Int64,
        availableByteBudget: Int64,
        destinationRoot: WorktreeIncludeDestinationRoot,
        createdItems: inout [WorktreeIncludeCreatedItem]
    ) throws {
        guard try !destinationRoot.itemExists(at: destinationRelativePath) else {
            throw CocoaError(.fileWriteFileExists)
        }

        let sourceDescriptor = Darwin.open(sourceItem.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard sourceDescriptor >= 0 else { throw posixError() }
        defer { Darwin.close(sourceDescriptor) }
        var sourceStatus = stat()
        guard fstat(sourceDescriptor, &sourceStatus) == 0 else { throw posixError() }
        guard sourceStatus.st_mode & S_IFMT == S_IFREG else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }

        let destinationDescriptor = try destinationRoot.createRegularFile(
            at: destinationRelativePath,
            permissions: 0o600
        )
        var destinationStatus = stat()
        guard fstat(destinationDescriptor, &destinationStatus) == 0 else {
            Darwin.close(destinationDescriptor)
            throw posixError()
        }
        createdItems.append(WorktreeIncludeCreatedItem(
            relativePath: destinationRelativePath,
            device: destinationStatus.st_dev,
            inode: destinationStatus.st_ino,
            isDirectory: false,
            directoryMetadataSource: nil
        ))
        destinationFileCreated(
            destinationRoot.rootURL.appendingPathComponent(destinationRelativePath)
        )

        defer { Darwin.close(destinationDescriptor) }
        byteCount = try destinationRoot.copyRegularFileContents(
            sourceDescriptor: sourceDescriptor,
            destinationDescriptor: destinationDescriptor,
            itemCount: itemCount,
            byteCount: byteCount,
            maximumByteCount: limits.maximumByteCount,
            availableByteBudget: availableByteBudget
        )
    }

    private func copySymbolicLink(
        _ sourceItem: URL,
        to destinationRelativePath: String,
        destinationRoot: WorktreeIncludeDestinationRoot,
        createdItems: inout [WorktreeIncludeCreatedItem]
    ) throws {
        let identity = try destinationRoot.copySymbolicLink(
            from: sourceItem,
            to: destinationRelativePath
        )
        createdItems.append(WorktreeIncludeCreatedItem(
            relativePath: destinationRelativePath,
            device: identity.device,
            inode: identity.inode,
            isDirectory: false,
            directoryMetadataSource: nil
        ))
    }

    private func posixError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    private func copyLimitDiagnostic(itemCount: Int, byteCount: Int64) -> String {
        "Skipped .worktreeinclude copy because its copy limit was exceeded (\(itemCount) items or \(byteCount) bytes)."
    }
}
