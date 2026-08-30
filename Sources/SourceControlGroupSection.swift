import Foundation

/// One non-empty status group and its immutable resource rows.
struct SourceControlGroupSection: Identifiable, Equatable, Sendable {
    let group: SourceControlGroup
    let resources: [SourceControlResourceRow]

    var id: SourceControlGroup { group }

    /// Builds the immutable Source Control projection used by the panel.
    ///
    /// Callers run this while a status result is being prepared, outside the
    /// SwiftUI render path. The panel can therefore consume the resulting
    /// sections without scanning, sorting, or touching the filesystem.
    static func makeSections(
        entries: [GitStatusSnapshotEntry],
        root: String
    ) -> [SourceControlGroupSection] {
        var grouped = Dictionary(
            uniqueKeysWithValues: SourceControlGroup.allCases.map { ($0, [SourceControlResourceRow]()) }
        )
        for entry in entries {
            let row = SourceControlResourceRow(
                path: entry.path,
                relativePath: relativePath(entry.path, root: root),
                status: entry.status
            )
            grouped[row.group, default: []].append(row)
        }

        return SourceControlGroup.allCases.compactMap { group in
            guard var resources = grouped[group], !resources.isEmpty else { return nil }
            resources.sort {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
            return SourceControlGroupSection(group: group, resources: resources)
        }
    }

    private static func relativePath(_ path: String, root: String) -> String {
        guard !root.isEmpty else { return path }
        let normalizedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        guard path.hasPrefix(normalizedRoot + "/") else { return path }
        return String(path.dropFirst(normalizedRoot.count + 1))
    }
}
