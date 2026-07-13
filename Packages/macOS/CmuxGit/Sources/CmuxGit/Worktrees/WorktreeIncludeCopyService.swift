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
            try? destination.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ).volumeAvailableCapacityForImportantUsage
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

        let availableByteBudget = availableCapacity(destination).map {
            max(0, $0 - limits.freeSpaceReserve)
        }
        if let availableByteBudget, byteCount > availableByteBudget {
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
                diagnostics.append("Cancelled .worktreeinclude copy before it completed.")
                break copyLoop
            } catch let limitError as WorktreeIncludeCopyLimitError {
                if !destinationExisted { try? fileManager.removeItem(at: destinationItem) }
                diagnostics.append(limitError.localizedDescription)
                break copyLoop
            } catch {
                if !destinationExisted { try? fileManager.removeItem(at: destinationItem) }
                diagnostics.append(
                    "Could not copy .worktreeinclude path \(relativePath): \(error.localizedDescription)"
                )
            }
        }
        for directory in copiedDirectories.reversed() {
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
        availableByteBudget: Int64?,
        destinationRoot: URL,
        copiedDirectories: inout [(source: URL, destination: URL)]
    ) throws {
        let rootValues = try sourceItem.resourceValues(forKeys: Self.resourceKeys)
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            try createDirectoryIfNeeded(
                destinationItem.deletingLastPathComponent(),
                from: sourceItem.deletingLastPathComponent(),
                destinationRoot: destinationRoot,
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

        try accountCopiedItem(itemCount: &itemCount, byteCount: byteCount)
        try createDirectoryIfNeeded(
            destinationItem,
            from: sourceItem,
            destinationRoot: destinationRoot,
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
                try accountCopiedItem(itemCount: &itemCount, byteCount: byteCount)
                try createDirectoryIfNeeded(
                    destinationChild,
                    from: child,
                    destinationRoot: destinationRoot,
                    copiedDirectories: &copiedDirectories
                )
            } else {
                try createDirectoryIfNeeded(
                    destinationChild.deletingLastPathComponent(),
                    from: child.deletingLastPathComponent(),
                    destinationRoot: destinationRoot,
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
            copiedDirectories: &copiedDirectories
        )
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: false)
        copiedDirectories.append((sourceDirectory, destinationDirectory))
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
        availableByteBudget: Int64?
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
                if let availableByteBudget, nextByteCount > availableByteBudget {
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
