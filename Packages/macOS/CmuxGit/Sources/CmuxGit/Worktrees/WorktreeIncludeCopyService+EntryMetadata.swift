import Darwin
import Foundation

extension WorktreeIncludeCopyService {
    func copyRegularFile(
        sourceRelativePath: String,
        to destinationRelativePath: String,
        reportedDestination: URL,
        itemCount: Int,
        byteCount: inout Int64,
        availableByteBudget: Int64,
        sourceRoot: WorktreeIncludeSourceRoot,
        destinationRoot: WorktreeIncludeDestinationRoot
    ) throws -> WorktreeIncludeCreatedItem {
        guard try !destinationRoot.itemExists(at: destinationRelativePath) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let sourceDescriptor = try sourceRoot.openRegularFile(at: sourceRelativePath)
        defer { Darwin.close(sourceDescriptor) }
        let attributes = try WorktreeIncludeExtendedAttributes(sourceDescriptor: sourceDescriptor)
        let destinationDescriptor = try destinationRoot.createRegularFile(
            at: destinationRelativePath,
            permissions: 0o600
        )
        defer { Darwin.close(destinationDescriptor) }
        var status = stat()
        guard fstat(destinationDescriptor, &status) == 0 else { throw posixError() }
        let createdItem = WorktreeIncludeCreatedItem(
            relativePath: destinationRelativePath,
            device: status.st_dev,
            inode: status.st_ino,
            isDirectory: false,
            directoryMetadataSourceRelativePath: nil
        )
        var keepItem = false
        defer {
            if !keepItem {
                try? destinationRoot.removeItemIfUnchanged(
                    at: createdItem.relativePath,
                    device: createdItem.device,
                    inode: createdItem.inode,
                    isDirectory: false
                )
            }
        }
        destinationFileCreated(reportedDestination)
        byteCount = try destinationRoot.copyRegularFileContents(
            sourceDescriptor: sourceDescriptor,
            destinationDescriptor: destinationDescriptor,
            itemCount: itemCount,
            byteCount: byteCount,
            maximumByteCount: limits.maximumByteCount,
            availableByteBudget: availableByteBudget
        )
        try accountMetadata(
            attributes.byteCount,
            itemCount: itemCount,
            byteCount: &byteCount,
            availableByteBudget: availableByteBudget
        )
        try destinationRoot.applySecurityMetadata(
            sourceDescriptor: sourceDescriptor,
            destinationDescriptor: destinationDescriptor
        )
        try attributes.apply(to: destinationDescriptor)
        keepItem = true
        return createdItem
    }

    func copySymbolicLink(
        sourceRelativePath: String,
        to destinationRelativePath: String,
        itemCount: Int,
        byteCount: inout Int64,
        availableByteBudget: Int64,
        sourceRoot: WorktreeIncludeSourceRoot,
        destinationRoot: WorktreeIncludeDestinationRoot
    ) throws -> WorktreeIncludeCreatedItem {
        guard try !destinationRoot.itemExists(at: destinationRelativePath) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let sourceDescriptor = try sourceRoot.openSymbolicLink(at: sourceRelativePath)
        defer { Darwin.close(sourceDescriptor) }
        let attributes = try WorktreeIncludeExtendedAttributes(sourceDescriptor: sourceDescriptor)
        let identity = try destinationRoot.createSymbolicLink(
            at: destinationRelativePath,
            target: sourceRoot.symbolicLinkTarget(at: sourceRelativePath)
        )
        let createdItem = WorktreeIncludeCreatedItem(
            relativePath: destinationRelativePath,
            device: identity.device,
            inode: identity.inode,
            isDirectory: false,
            directoryMetadataSourceRelativePath: nil
        )
        var keepItem = false
        defer {
            if !keepItem {
                try? destinationRoot.removeItemIfUnchanged(
                    at: createdItem.relativePath,
                    device: createdItem.device,
                    inode: createdItem.inode,
                    isDirectory: false
                )
            }
        }
        let destinationDescriptor = try destinationRoot.openSymbolicLink(at: destinationRelativePath)
        defer { Darwin.close(destinationDescriptor) }
        try accountMetadata(
            attributes.byteCount,
            itemCount: itemCount,
            byteCount: &byteCount,
            availableByteBudget: availableByteBudget
        )
        try attributes.apply(to: destinationDescriptor)
        keepItem = true
        return createdItem
    }

    func applyDirectoryTreeMetadata(
        _ sourceDirectory: URL,
        stagedRootPath: String,
        itemCount: Int,
        byteCount: inout Int64,
        availableByteBudget: Int64,
        sourceRoot: WorktreeIncludeSourceRoot,
        destinationRoot: WorktreeIncludeDestinationRoot
    ) throws {
        var pending: [(source: String, destination: String, depth: Int)] = []
        guard let enumerator = fileManager.enumerator(atPath: sourceDirectory.path) else {
            throw CocoaError(.fileReadUnknown)
        }
        while let relativePath = enumerator.nextObject() as? String {
            let depth = enumerator.level
            while let last = pending.last, last.depth >= depth {
                let directory = pending.removeLast()
                try applyDirectoryMetadata(
                    sourceRelativePath: directory.source,
                    destinationRelativePath: directory.destination,
                    expectedIdentity: nil,
                    itemCount: itemCount,
                    byteCount: &byteCount,
                    availableByteBudget: availableByteBudget,
                    sourceRoot: sourceRoot,
                    destinationRoot: destinationRoot
                )
            }
            let child = sourceDirectory.appendingPathComponent(relativePath)
            let values = try child.resourceValues(forKeys: WorktreeIncludeSourceRoot.resourceKeys)
            if values.isDirectory == true, values.isSymbolicLink != true {
                pending.append((
                    try sourceRoot.relativePath(for: child),
                    stagedRootPath + "/" + relativePath,
                    depth
                ))
            }
        }
        for directory in pending.reversed() {
            try applyDirectoryMetadata(
                sourceRelativePath: directory.source,
                destinationRelativePath: directory.destination,
                expectedIdentity: nil,
                itemCount: itemCount,
                byteCount: &byteCount,
                availableByteBudget: availableByteBudget,
                sourceRoot: sourceRoot,
                destinationRoot: destinationRoot
            )
        }
        try applyDirectoryMetadata(
            sourceRelativePath: try sourceRoot.relativePath(for: sourceDirectory),
            destinationRelativePath: stagedRootPath,
            expectedIdentity: nil,
            itemCount: itemCount,
            byteCount: &byteCount,
            availableByteBudget: availableByteBudget,
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot
        )
    }
}
