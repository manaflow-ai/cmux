import Darwin
import Foundation

/// Resolves one exact ordinary file path without walking the artifact tree.
struct ArtifactExactPathResolver {
    func fileNode(relativePath: String, paths: ArtifactStorePaths) throws -> ArtifactNode? {
        guard !relativePath.isEmpty,
              !relativePath.contains("\0"),
              !relativePath.contains("\n") else {
            return nil
        }
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              components.joined(separator: "/") == relativePath,
              components.first != ".cmux",
              components.last != ArtifactPathResolver.workspaceMarkerName,
              components.last != ArtifactPathResolver.sessionMarkerName else {
            return nil
        }

        var current = paths.artifactsRoot
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component, isDirectory: index < components.count - 1)
            guard let entryType = try filesystemEntryType(current) else { return nil }
            guard entryType != S_IFLNK else {
                throw ArtifactStoreError.pathOutsideStore(current.path)
            }
            if index < components.count - 1 {
                guard entryType == S_IFDIR else { return nil }
            } else {
                guard entryType == S_IFREG else { return nil }
            }
        }

        let values = try current.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            return nil
        }
        return ArtifactNode(
            id: relativePath,
            name: current.lastPathComponent,
            relativePath: relativePath,
            absolutePath: current.path,
            isDirectory: false,
            fileKind: ArtifactFileKind.classify(current),
            size: values.fileSize.map(Int64.init),
            modifiedAt: values.contentModificationDate,
            children: []
        )
    }

    private func filesystemEntryType(_ url: URL) throws -> mode_t? {
        var status = stat()
        if lstat(url.path, &status) == 0 {
            return status.st_mode & S_IFMT
        }
        guard errno == ENOENT else {
            throw CocoaError(.fileReadUnknown)
        }
        return nil
    }
}
