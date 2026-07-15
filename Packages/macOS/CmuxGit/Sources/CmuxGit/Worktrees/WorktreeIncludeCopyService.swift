import Darwin
import Foundation

/// Copies selected worktree paths with aggregate item, byte, disk, and cancellation guards.
struct WorktreeIncludeCopyService: Sendable {
    // FileManager operations used here are documented thread-safe, and this
    // immutable injected instance has no delegate or mutable caller-owned state.
    nonisolated(unsafe) let fileManager: FileManager
    let limits: WorktreeIncludeCopyLimits
    let availableCapacity: @Sendable (URL) -> Int64?
    let destinationFileCreated: @Sendable (URL) -> Void
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
        let sourceRoot: WorktreeIncludeSourceRoot
        do {
            sourceRoot = try WorktreeIncludeSourceRoot(rootURL: source)
        } catch {
            return [
                "Skipped .worktreeinclude copy because the source root could not be opened safely: \(error.localizedDescription)"
            ]
        }

        for relativePath in relativePaths {
            if Task.isCancelled {
                return diagnostics + ["Cancelled .worktreeinclude copy before it completed."]
            }
            let sourceItem = source.appendingPathComponent(relativePath).standardizedFileURL
            do {
                try sourceRoot.preflight(
                    sourceItem,
                    fileManager: fileManager,
                    limits: limits,
                    itemCount: &itemCount,
                    byteCount: &byteCount
                )
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
            return diagnostics + [
                "Skipped .worktreeinclude copy because the destination volume's available capacity could not be determined."
            ]
        }
        guard availableCapacity > limits.freeSpaceReserve else {
            return diagnostics + [
                "Skipped .worktreeinclude copy because the destination volume lacks sufficient free space."
            ]
        }
        let availableByteBudget = availableCapacity - limits.freeSpaceReserve
        guard byteCount <= availableByteBudget else {
            return diagnostics + [
                "Skipped .worktreeinclude copy because the destination volume lacks sufficient free space."
            ]
        }

        let destinationRoot: WorktreeIncludeDestinationRoot
        do {
            destinationRoot = try WorktreeIncludeDestinationRoot(rootURL: destination)
        } catch {
            return diagnostics + [
                "Skipped .worktreeinclude copy because a checkout root could not be opened safely: \(error.localizedDescription)"
            ]
        }

        copyLoop: for relativePath in copyablePaths {
            if Task.isCancelled {
                diagnostics.append("Cancelled .worktreeinclude copy before it completed.")
                break
            }
            do {
                diagnostics += try copyCandidate(
                    relativePath,
                    sourceRoot: sourceRoot,
                    destinationRoot: destinationRoot,
                    itemCount: &copiedItemCount,
                    byteCount: &copiedByteCount,
                    availableByteBudget: availableByteBudget
                )
            } catch is CancellationError {
                diagnostics.append("Cancelled .worktreeinclude copy before it completed.")
                break copyLoop
            } catch let error as WorktreeIncludeCopyLimitError {
                diagnostics.append(error.localizedDescription)
                break copyLoop
            } catch {
                diagnostics.append(
                    "Could not copy .worktreeinclude path \(relativePath): \(error.localizedDescription)"
                )
            }
        }
        return diagnostics
    }

    private func copyCandidate(
        _ relativePath: String,
        sourceRoot: WorktreeIncludeSourceRoot,
        destinationRoot: WorktreeIncludeDestinationRoot,
        itemCount: inout Int,
        byteCount: inout Int64,
        availableByteBudget: Int64
    ) throws -> [String] {
        let sourceItem = sourceRoot.rootURL.appendingPathComponent(relativePath).standardizedFileURL
        let destinationItem = destinationRoot.rootURL
            .appendingPathComponent(relativePath).standardizedFileURL
        let destinationRelativePath = try destinationRoot.relativePath(for: destinationItem)
        let sourceValues = try sourceItem.resourceValues(forKeys: WorktreeIncludeSourceRoot.resourceKeys)
        sourceItemInspected(sourceItem)

        var createdItems: [WorktreeIncludeCreatedItem] = []
        do {
            try createDirectoryIfNeeded(
                destinationItem.deletingLastPathComponent(),
                from: sourceItem.deletingLastPathComponent(),
                sourceRoot: sourceRoot,
                destinationRoot: destinationRoot,
                itemCount: &itemCount,
                byteCount: byteCount,
                createdItems: &createdItems
            )
            if sourceValues.isDirectory == true, sourceValues.isSymbolicLink != true {
                try copyDirectoryCandidate(
                    sourceItem,
                    to: destinationRelativePath,
                    sourceRoot: sourceRoot,
                    destinationRoot: destinationRoot,
                    itemCount: &itemCount,
                    byteCount: &byteCount,
                    availableByteBudget: availableByteBudget
                )
            } else {
                try accountCopiedItem(
                    itemCount: &itemCount,
                    byteCount: byteCount,
                    destinationRoot: destinationRoot
                )
                let createdItem: WorktreeIncludeCreatedItem
                if sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true {
                    createdItem = try copyRegularFile(
                        sourceRelativePath: try sourceRoot.relativePath(for: sourceItem),
                        to: destinationRelativePath,
                        reportedDestination: destinationItem,
                        itemCount: itemCount,
                        byteCount: &byteCount,
                        availableByteBudget: availableByteBudget,
                        sourceRoot: sourceRoot,
                        destinationRoot: destinationRoot
                    )
                } else if sourceValues.isSymbolicLink == true {
                    createdItem = try copySymbolicLink(
                        sourceRelativePath: try sourceRoot.relativePath(for: sourceItem),
                        to: destinationRelativePath,
                        itemCount: itemCount,
                        byteCount: &byteCount,
                        availableByteBudget: availableByteBudget,
                        sourceRoot: sourceRoot,
                        destinationRoot: destinationRoot
                    )
                } else {
                    throw CocoaError(.fileReadUnsupportedScheme)
                }
                createdItems.append(createdItem)
            }
        } catch {
            removeCreatedItems(destinationRoot: destinationRoot, createdItems: &createdItems)
            throw error
        }

        var metadataDiagnostics: [String] = []
        for directory in createdItems.reversed() where directory.isDirectory {
            guard let sourceRelativePath = directory.directoryMetadataSourceRelativePath else { continue }
            do {
                try applyDirectoryMetadata(
                    sourceRelativePath: sourceRelativePath,
                    destinationRelativePath: directory.relativePath,
                    expectedIdentity: (directory.device, directory.inode),
                    itemCount: itemCount,
                    byteCount: &byteCount,
                    availableByteBudget: availableByteBudget,
                    sourceRoot: sourceRoot,
                    destinationRoot: destinationRoot
                )
            } catch {
                metadataDiagnostics.append(
                    "Could not preserve .worktreeinclude directory metadata for \(URL(fileURLWithPath: sourceRelativePath).lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
        return metadataDiagnostics
    }

    private func copyDirectoryCandidate(
        _ sourceDirectory: URL,
        to destinationRelativePath: String,
        sourceRoot: WorktreeIncludeSourceRoot,
        destinationRoot: WorktreeIncludeDestinationRoot,
        itemCount: inout Int,
        byteCount: inout Int64,
        availableByteBudget: Int64
    ) throws {
        guard try !destinationRoot.itemExists(at: destinationRelativePath) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let staging = try destinationRoot.createStagingRoot()
        defer {
            try? destinationRoot.removeStagingRootIfUnchanged(
                named: staging.name,
                device: staging.device,
                inode: staging.inode
            )
        }
        let stagedName = "candidate"
        try accountCopiedItem(
            itemCount: &itemCount,
            byteCount: byteCount,
            destinationRoot: destinationRoot
        )
        _ = try staging.root.createDirectory(at: stagedName, permissions: 0o700)

        guard let enumerator = fileManager.enumerator(atPath: sourceDirectory.path) else {
            throw CocoaError(.fileReadUnknown)
        }
        while let relativePath = enumerator.nextObject() as? String {
            if Task.isCancelled { throw CancellationError() }
            let sourceChild = sourceDirectory.appendingPathComponent(relativePath)
            let stagedRelativePath = stagedName + "/" + relativePath
            let values = try sourceChild.resourceValues(forKeys: WorktreeIncludeSourceRoot.resourceKeys)
            try accountCopiedItem(
                itemCount: &itemCount,
                byteCount: byteCount,
                destinationRoot: destinationRoot
            )
            if values.isDirectory == true, values.isSymbolicLink != true {
                _ = try staging.root.createDirectory(at: stagedRelativePath, permissions: 0o700)
            } else if values.isRegularFile == true, values.isSymbolicLink != true {
                _ = try copyRegularFile(
                    sourceRelativePath: try sourceRoot.relativePath(for: sourceChild),
                    to: stagedRelativePath,
                    reportedDestination: staging.root.rootURL.appendingPathComponent(stagedRelativePath),
                    itemCount: itemCount,
                    byteCount: &byteCount,
                    availableByteBudget: availableByteBudget,
                    sourceRoot: sourceRoot,
                    destinationRoot: staging.root
                )
            } else if values.isSymbolicLink == true {
                _ = try copySymbolicLink(
                    sourceRelativePath: try sourceRoot.relativePath(for: sourceChild),
                    to: stagedRelativePath,
                    itemCount: itemCount,
                    byteCount: &byteCount,
                    availableByteBudget: availableByteBudget,
                    sourceRoot: sourceRoot,
                    destinationRoot: staging.root
                )
            } else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
        }

        try applyDirectoryTreeMetadata(
            sourceDirectory,
            stagedRootPath: stagedName,
            itemCount: itemCount,
            byteCount: &byteCount,
            availableByteBudget: availableByteBudget,
            sourceRoot: sourceRoot,
            destinationRoot: staging.root
        )
        try destinationRoot.installStagedItem(
            named: stagedName,
            from: staging.root,
            at: destinationRelativePath
        )
    }

    private func createDirectoryIfNeeded(
        _ destinationDirectory: URL,
        from sourceDirectory: URL,
        sourceRoot: WorktreeIncludeSourceRoot,
        destinationRoot: WorktreeIncludeDestinationRoot,
        itemCount: inout Int,
        byteCount: Int64,
        createdItems: inout [WorktreeIncludeCreatedItem]
    ) throws {
        let relativePath = try destinationRoot.relativePath(for: destinationDirectory.standardizedFileURL)
        guard !relativePath.isEmpty,
              try !destinationRoot.directoryExists(at: relativePath) else { return }
        try createDirectoryIfNeeded(
            destinationDirectory.deletingLastPathComponent(),
            from: sourceDirectory.deletingLastPathComponent(),
            sourceRoot: sourceRoot,
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
            directoryMetadataSourceRelativePath: try sourceRoot.relativePath(for: sourceDirectory)
        ))
    }

    private func removeCreatedItems(
        destinationRoot: WorktreeIncludeDestinationRoot,
        createdItems: inout [WorktreeIncludeCreatedItem]
    ) {
        for item in createdItems.reversed() {
            try? destinationRoot.removeItemIfUnchanged(
                at: item.relativePath,
                device: item.device,
                inode: item.inode,
                isDirectory: item.isDirectory
            )
        }
        createdItems.removeAll(keepingCapacity: false)
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

    func accountMetadata(
        _ metadataByteCount: Int64,
        itemCount: Int,
        byteCount: inout Int64,
        availableByteBudget: Int64
    ) throws {
        let nextByteCount = byteCount + metadataByteCount
        guard nextByteCount <= limits.maximumByteCount else {
            throw WorktreeIncludeCopyLimitError(
                itemCount: itemCount,
                byteCount: nextByteCount,
                reason: .resourceLimit
            )
        }
        guard nextByteCount <= availableByteBudget else {
            throw WorktreeIncludeCopyLimitError(
                itemCount: itemCount,
                byteCount: nextByteCount,
                reason: .capacity
            )
        }
        byteCount = nextByteCount
    }

    func applyDirectoryMetadata(
        sourceRelativePath: String,
        destinationRelativePath: String,
        expectedIdentity: (device: dev_t, inode: ino_t)?,
        itemCount: Int,
        byteCount: inout Int64,
        availableByteBudget: Int64,
        sourceRoot: WorktreeIncludeSourceRoot,
        destinationRoot: WorktreeIncludeDestinationRoot
    ) throws {
        let sourceDescriptor = try sourceRoot.openDirectory(at: sourceRelativePath)
        defer { Darwin.close(sourceDescriptor) }
        let attributes = try WorktreeIncludeExtendedAttributes(sourceDescriptor: sourceDescriptor)
        try accountMetadata(
            attributes.byteCount,
            itemCount: itemCount,
            byteCount: &byteCount,
            availableByteBudget: availableByteBudget
        )
        if let expectedIdentity {
            try destinationRoot.applySecurityMetadata(
                sourceDescriptor: sourceDescriptor,
                to: destinationRelativePath,
                expectedDevice: expectedIdentity.device,
                expectedInode: expectedIdentity.inode,
                extendedAttributes: attributes
            )
        } else {
            let destinationDescriptor = try destinationRoot.openDirectory(at: destinationRelativePath)
            defer { Darwin.close(destinationDescriptor) }
            try destinationRoot.applySecurityMetadata(
                sourceDescriptor: sourceDescriptor,
                destinationDescriptor: destinationDescriptor
            )
            try attributes.apply(to: destinationDescriptor)
        }
    }

    func posixError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    private func copyLimitDiagnostic(itemCount: Int, byteCount: Int64) -> String {
        "Skipped .worktreeinclude copy because its copy limit was exceeded (\(itemCount) items or \(byteCount) bytes)."
    }
}
