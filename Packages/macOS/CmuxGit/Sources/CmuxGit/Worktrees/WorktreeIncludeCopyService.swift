import Foundation

/// Copies selected worktree paths with aggregate item, byte, disk, and cancellation guards.
struct WorktreeIncludeCopyService: Sendable {
    private static let maximumItemCount = 500_000
    private static let maximumByteCount: Int64 = 50 * 1024 * 1024 * 1024
    private static let freeSpaceReserve: Int64 = 512 * 1024 * 1024
    private static let resourceKeys: Set<URLResourceKey> = [
        .fileSizeKey,
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
    ]

    // FileManager operations used here are documented thread-safe, and this
    // immutable injected instance has no delegate or mutable caller-owned state.
    private nonisolated(unsafe) let fileManager: FileManager

    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    func copy(relativePaths: [String], from source: URL, to destination: URL) -> [String] {
        var diagnostics: [String] = []
        var copyablePaths: [String] = []
        var itemCount = 0
        var byteCount: Int64 = 0

        for relativePath in relativePaths {
            if Task.isCancelled {
                return diagnostics + ["Cancelled .worktreeinclude copy before it completed."]
            }
            let sourceItem = source.appendingPathComponent(relativePath).standardizedFileURL
            do {
                try preflight(sourceItem, itemCount: &itemCount, byteCount: &byteCount)
                copyablePaths.append(relativePath)
            } catch {
                diagnostics.append(
                    "Could not inspect .worktreeinclude path \(relativePath): \(error.localizedDescription)"
                )
            }
            if itemCount > Self.maximumItemCount || byteCount > Self.maximumByteCount {
                diagnostics.append(copyLimitDiagnostic(itemCount: itemCount, byteCount: byteCount))
                return diagnostics
            }
        }

        if let available = try? destination.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage,
           byteCount > max(0, available - Self.freeSpaceReserve) {
            diagnostics.append(
                "Skipped .worktreeinclude copy because the destination volume lacks sufficient free space."
            )
            return diagnostics
        }

        for relativePath in copyablePaths {
            if Task.isCancelled {
                diagnostics.append("Cancelled .worktreeinclude copy before it completed.")
                return diagnostics
            }
            do {
                try copyItem(
                    source.appendingPathComponent(relativePath).standardizedFileURL,
                    to: destination.appendingPathComponent(relativePath).standardizedFileURL
                )
            } catch {
                diagnostics.append(
                    "Could not copy .worktreeinclude path \(relativePath): \(error.localizedDescription)"
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
        guard let enumerator = fileManager.enumerator(
            at: sourceItem,
            includingPropertiesForKeys: Array(Self.resourceKeys),
            options: []
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        while let child = enumerator.nextObject() as? URL {
            if Task.isCancelled { throw CancellationError() }
            let values = try child.resourceValues(forKeys: Self.resourceKeys)
            account(values, itemCount: &itemCount, byteCount: &byteCount)
            if itemCount > Self.maximumItemCount || byteCount > Self.maximumByteCount {
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
        if values.isRegularFile == true, let size = values.fileSize {
            byteCount += Int64(size)
        }
    }

    private func copyItem(_ sourceItem: URL, to destinationItem: URL) throws {
        let rootValues = try sourceItem.resourceValues(forKeys: Self.resourceKeys)
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            try fileManager.createDirectory(
                at: destinationItem.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: sourceItem, to: destinationItem)
            return
        }

        try fileManager.createDirectory(at: destinationItem, withIntermediateDirectories: true)
        guard let enumerator = fileManager.enumerator(
            at: sourceItem,
            includingPropertiesForKeys: Array(Self.resourceKeys),
            options: []
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        while let child = enumerator.nextObject() as? URL {
            if Task.isCancelled { throw CancellationError() }
            var destinationChild = destinationItem
            for component in child.pathComponents.suffix(enumerator.level) {
                destinationChild.appendPathComponent(component)
            }
            let values = try child.resourceValues(forKeys: Self.resourceKeys)
            if values.isDirectory == true, values.isSymbolicLink != true {
                try fileManager.createDirectory(at: destinationChild, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(
                    at: destinationChild.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: child, to: destinationChild)
            }
        }
    }

    private func copyLimitDiagnostic(itemCount: Int, byteCount: Int64) -> String {
        "Skipped .worktreeinclude copy because its copy limit was exceeded (\(itemCount) items or \(byteCount) bytes)."
    }
}
