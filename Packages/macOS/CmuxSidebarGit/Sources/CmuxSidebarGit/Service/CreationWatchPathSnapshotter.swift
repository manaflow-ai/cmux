import Foundation
internal import CmuxGit

/// Collects bounded creation-watch filesystem state off the main actor.
struct CreationWatchPathSnapshotter: Sendable {
    private let fileManager: FileManager

    /// Creates a snapshotter backed by an injectable filesystem provider.
    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    /// Reads target existence, resolved ancestors, and symlink state.
    @concurrent
    func snapshots(
        for paths: [String]
    ) async -> [String: WorkspaceGitMetadataCreationTargetSnapshot] {
        let boundedPaths = paths.prefix(2_048)
        var snapshots: [String: WorkspaceGitMetadataCreationTargetSnapshot] = [:]
        snapshots.reserveCapacity(boundedPaths.count)
        for path in boundedPaths {
            guard !Task.isCancelled else { break }
            snapshots[path] = WorkspaceGitMetadataCreationTargetSnapshot(
                exists: fileManager.fileExists(atPath: path),
                nearestExistingDirectory: nearestExistingDirectory(for: path),
                logicalSymlinkParent: logicalSymlinkParent(for: path),
                logicalSymlinkSignature: logicalSymlinkSignature(for: path)
            )
        }
        return snapshots
    }

    private func nearestExistingDirectory(for path: String) -> String {
        var candidate = URL(fileURLWithPath: path).deletingLastPathComponent()
        while candidate.path != "/" {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(
                atPath: candidate.path,
                isDirectory: &isDirectory
            ),
               isDirectory.boolValue {
                return candidate
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                    .path
            }
            candidate.deleteLastPathComponent()
        }
        return "/"
    }

    private func logicalSymlinkParent(for path: String) -> String? {
        var current = URL(fileURLWithPath: "/")
        for component in path.split(separator: "/") {
            let next = current.appendingPathComponent(String(component))
            if (try? fileManager.destinationOfSymbolicLink(atPath: next.path)) != nil {
                let parent = current.standardizedFileURL.path
                return parent == "/" ? nil : parent
            }
            current = next
        }
        return nil
    }

    private func logicalSymlinkSignature(for path: String) -> String? {
        var current = URL(fileURLWithPath: "/")
        var components: [String] = []
        for component in path.split(separator: "/") {
            let next = current.appendingPathComponent(String(component))
            if let destination = try? fileManager.destinationOfSymbolicLink(
                atPath: next.path
            ) {
                components.append("\(next.path)=\(destination)")
            }
            current = next
        }
        return components.isEmpty ? nil : components.joined(separator: "|")
    }
}
