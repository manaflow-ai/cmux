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
        }
    ) {
        self.fileManager = fileManager
        self.limits = limits
        self.availableCapacity = availableCapacity
    }

    func copy(relativePaths: [String], from source: URL, to destination: URL) -> [String] {
        var diagnostics: [String] = []
        var copyablePaths: [String] = []
        var itemCount = 0
        var byteCount: Int64 = 0
        var copiedItemCount = 0
        var copiedByteCount: Int64 = 0
        var copiedDirectories: [(source: URL, destination: URL)] = []

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
        let availableByteBudget = max(0, availableCapacity - limits.freeSpaceReserve)
        if byteCount > availableByteBudget {
            diagnostics.append(
                "Skipped .worktreeinclude copy because the destination volume lacks sufficient free space."
            )
            return diagnostics
        }

        copyLoop: for relativePath in copyablePaths {
            if Task.isCancelled {
                diagnostics.append("Cancelled .worktreeinclude copy before it completed.")
                break copyLoop
            }
            let destinationItem = destination.appendingPathComponent(relativePath).standardizedFileURL
            let destinationExisted = fileManager.fileExists(atPath: destinationItem.path)
            let copiedDirectoryStartIndex = copiedDirectories.count
            do {
                try copyItem(
                    source.appendingPathComponent(relativePath).standardizedFileURL,
                    to: destinationItem,
                    itemCount: &copiedItemCount,
                    byteCount: &copiedByteCount,
                    availableByteBudget: availableByteBudget,
                    destinationRoot: destination,
                    copiedDirectories: &copiedDirectories
                )
            } catch is CancellationError {
                if !destinationExisted { try? fileManager.removeItem(at: destinationItem) }
                removeCopiedDirectories(
                    since: copiedDirectoryStartIndex,
                    copiedDirectories: &copiedDirectories
                )
                diagnostics.append("Cancelled .worktreeinclude copy before it completed.")
                break copyLoop
            } catch let limitError as WorktreeIncludeCopyLimitError {
                if !destinationExisted { try? fileManager.removeItem(at: destinationItem) }
                removeCopiedDirectories(
                    since: copiedDirectoryStartIndex,
                    copiedDirectories: &copiedDirectories
                )
                diagnostics.append(limitError.localizedDescription)
                break copyLoop
            } catch {
                if !destinationExisted { try? fileManager.removeItem(at: destinationItem) }
                removeCopiedDirectories(
                    since: copiedDirectoryStartIndex,
                    copiedDirectories: &copiedDirectories
                )
                diagnostics.append(
                    "Could not copy .worktreeinclude path \(relativePath): \(error.localizedDescription)"
                )
            }
        }
        for directory in copiedDirectories.reversed() {
            if Task.isCancelled {
                if !diagnostics.contains(where: { $0.localizedCaseInsensitiveContains("cancelled") }) {
                    diagnostics.append("Cancelled .worktreeinclude copy before it completed.")
                }
                break
            }
            guard fileManager.fileExists(atPath: directory.destination.path) else { continue }
            do {
                try copySecurityMetadata(from: directory.source, to: directory.destination)
            } catch {
                try? fileManager.removeItem(at: directory.destination)
                diagnostics.append(
                    "Could not preserve .worktreeinclude directory metadata for \(directory.source.lastPathComponent): \(error.localizedDescription)"
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
        itemCount: inout Int,
        byteCount: inout Int64,
        availableByteBudget: Int64,
        destinationRoot: URL,
        copiedDirectories: inout [(source: URL, destination: URL)]
    ) throws {
        let rootValues = try sourceItem.resourceValues(forKeys: Self.resourceKeys)
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            try createDirectoryIfNeeded(
                destinationItem.deletingLastPathComponent(),
                from: sourceItem.deletingLastPathComponent(),
                destinationRoot: destinationRoot,
                itemCount: &itemCount,
                byteCount: byteCount,
                copiedDirectories: &copiedDirectories
            )
            try accountCopiedItem(itemCount: &itemCount, byteCount: byteCount)
            if rootValues.isRegularFile == true, rootValues.isSymbolicLink != true {
                try copyRegularFile(
                    sourceItem,
                    to: destinationItem,
                    itemCount: itemCount,
                    byteCount: &byteCount,
                    availableByteBudget: availableByteBudget
                )
            } else {
                try fileManager.copyItem(at: sourceItem, to: destinationItem)
            }
            return
        }

        try createDirectoryIfNeeded(
            destinationItem,
            from: sourceItem,
            destinationRoot: destinationRoot,
            itemCount: &itemCount,
            byteCount: byteCount,
            copiedDirectories: &copiedDirectories
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
                    copiedDirectories: &copiedDirectories
                )
            } else {
                try createDirectoryIfNeeded(
                    destinationChild.deletingLastPathComponent(),
                    from: child.deletingLastPathComponent(),
                    destinationRoot: destinationRoot,
                    itemCount: &itemCount,
                    byteCount: byteCount,
                    copiedDirectories: &copiedDirectories
                )
                try accountCopiedItem(itemCount: &itemCount, byteCount: byteCount)
                if values.isRegularFile == true, values.isSymbolicLink != true {
                    try copyRegularFile(
                        child,
                        to: destinationChild,
                        itemCount: itemCount,
                        byteCount: &byteCount,
                        availableByteBudget: availableByteBudget
                    )
                } else {
                    try fileManager.copyItem(at: child, to: destinationChild)
                }
            }
        }
    }

    private func createDirectoryIfNeeded(
        _ destinationDirectory: URL,
        from sourceDirectory: URL,
        destinationRoot: URL,
        itemCount: inout Int,
        byteCount: Int64,
        copiedDirectories: inout [(source: URL, destination: URL)]
    ) throws {
        let destinationDirectory = destinationDirectory.standardizedFileURL
        guard destinationDirectory != destinationRoot.standardizedFileURL,
              !fileManager.fileExists(atPath: destinationDirectory.path) else {
            return
        }
        try createDirectoryIfNeeded(
            destinationDirectory.deletingLastPathComponent(),
            from: sourceDirectory.deletingLastPathComponent(),
            destinationRoot: destinationRoot,
            itemCount: &itemCount,
            byteCount: byteCount,
            copiedDirectories: &copiedDirectories
        )
        try accountCopiedItem(itemCount: &itemCount, byteCount: byteCount)
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: false)
        copiedDirectories.append((sourceDirectory, destinationDirectory))
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: destinationDirectory.path
        )
    }

    private func removeCopiedDirectories(
        since startIndex: Int,
        copiedDirectories: inout [(source: URL, destination: URL)]
    ) {
        guard startIndex < copiedDirectories.count else { return }
        for directory in copiedDirectories[startIndex...].reversed() {
            try? fileManager.removeItem(at: directory.destination)
        }
        copiedDirectories.removeSubrange(startIndex...)
    }

    private func accountCopiedItem(
        itemCount: inout Int,
        byteCount: Int64
    ) throws {
        itemCount += 1
        guard itemCount <= limits.maximumItemCount else {
            throw WorktreeIncludeCopyLimitError(
                itemCount: itemCount,
                byteCount: byteCount,
                reason: .resourceLimit
            )
        }
    }

    private func copyRegularFile(
        _ sourceItem: URL,
        to destinationItem: URL,
        itemCount: Int,
        byteCount: inout Int64,
        availableByteBudget: Int64
    ) throws {
        guard !fileManager.fileExists(atPath: destinationItem.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        guard fileManager.createFile(atPath: destinationItem.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            let sourceHandle = try FileHandle(forReadingFrom: sourceItem)
            defer { try? sourceHandle.close() }
            let destinationHandle = try FileHandle(forWritingTo: destinationItem)
            defer { try? destinationHandle.close() }

            while true {
                if Task.isCancelled { throw CancellationError() }
                guard let data = try sourceHandle.read(upToCount: 64 * 1024), !data.isEmpty else {
                    break
                }
                let nextByteCount = byteCount + Int64(data.count)
                guard nextByteCount <= limits.maximumByteCount else {
                    throw WorktreeIncludeCopyLimitError(
                        itemCount: itemCount,
                        byteCount: nextByteCount,
                        reason: .resourceLimit
                    )
                }
                if nextByteCount > availableByteBudget {
                    throw WorktreeIncludeCopyLimitError(
                        itemCount: itemCount,
                        byteCount: nextByteCount,
                        reason: .capacity
                    )
                }
                try destinationHandle.write(contentsOf: data)
                byteCount = nextByteCount
            }

            try copySecurityMetadata(from: sourceItem, to: destinationItem)
        } catch {
            try? fileManager.removeItem(at: destinationItem)
            throw error
        }
    }

    private func copySecurityMetadata(from source: URL, to destination: URL) throws {
        guard copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_SECURITY)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func copyLimitDiagnostic(itemCount: Int, byteCount: Int64) -> String {
        "Skipped .worktreeinclude copy because its copy limit was exceeded (\(itemCount) items or \(byteCount) bytes)."
    }
}
