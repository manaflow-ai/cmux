import Foundation

/// Applies the filesystem eligibility rules shared by gallery pages and row counts.
public struct ChatArtifactGalleryRowEligibility: Sendable {
    /// Creates a gallery row eligibility evaluator.
    public init() {}

    /// Builds the eligible gallery rows for transcript references.
    ///
    /// A failed stat becomes a missing row only when `includeMissing` is true.
    /// Directory rows are omitted unless `includeDirectories` is true.
    ///
    /// - Parameters:
    ///   - references: Transcript references to stat and project into rows.
    ///   - includeDirectories: Whether directories are eligible gallery rows.
    ///   - includeMissing: Whether references that fail stat remain as missing rows.
    /// - Returns: Gallery rows that satisfy both eligibility flags.
    public func rows(
        _ references: [ChatArtifactIndexedReference],
        includeDirectories: Bool,
        includeMissing: Bool
    ) -> [ChatArtifactGalleryItem] {
        references.compactMap {
            row(
                for: $0,
                includeDirectories: includeDirectories,
                includeMissing: includeMissing
            )
        }
    }

    /// Counts the rows in the gallery's default unfiltered, recent session view.
    ///
    /// - Parameters:
    ///   - items: De-duplicated transcript references from one index snapshot.
    ///   - orderedItems: Optional generation-cached ordering of `items`.
    ///   - includeDirectories: Whether directories are eligible gallery rows.
    ///   - includeMissing: Whether references that fail stat remain as missing rows.
    /// - Returns: The number of rows the default gallery view renders.
    /// Counting is existence-only: one `fileExists` syscall per reference,
    /// no `ChatArtifactGalleryItem` construction, no directory child
    /// enumeration, and no `ArtifactByteReader.stat` (which can read file
    /// bytes to classify extension-less files). Ordering and provenance
    /// grouping cannot change a total, so `orderedItems` is accepted for
    /// call-site symmetry but not required.
    public func defaultRowCount(
        _ items: [ChatArtifactIndexedReference],
        orderedItems: [ChatArtifactIndexedReference]? = nil,
        includeDirectories: Bool,
        includeMissing: Bool
    ) -> Int {
        (orderedItems ?? items).count { reference in
            isEligible(
                reference,
                includeDirectories: includeDirectories,
                includeMissing: includeMissing
            )
        }
    }

    /// Cheap eligibility for count-only scans: same rule as page rows, fed
    /// from one attributes read. `attributesOfItem` observes a symlink itself
    /// (matching `ArtifactByteReader.stat`), where `fileExists` would traverse
    /// it and disagree with the gallery about dangling links.
    public func isEligible(
        _ reference: ChatArtifactIndexedReference,
        includeDirectories: Bool,
        includeMissing: Bool
    ) -> Bool {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: reference.path)
            let isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
            return Self.isRowIncluded(
                exists: true,
                isDirectory: isDirectory,
                includeDirectories: includeDirectories,
                includeMissing: includeMissing
            )
        } catch {
            return Self.isRowIncluded(
                exists: false,
                isDirectory: false,
                includeDirectories: includeDirectories,
                includeMissing: includeMissing
            )
        }
    }

    /// The single row-inclusion rule shared by page rows and count-only
    /// scans. Both feed it their own filesystem observation; the decision
    /// logic itself cannot drift.
    static func isRowIncluded(
        exists: Bool,
        isDirectory: Bool,
        includeDirectories: Bool,
        includeMissing: Bool
    ) -> Bool {
        guard exists else { return includeMissing }
        return includeDirectories || !isDirectory
    }

    func defaultCandidates(
        _ items: [ChatArtifactIndexedReference],
        orderedItems: [ChatArtifactIndexedReference]? = nil
    ) -> (
        created: [ChatArtifactIndexedReference],
        attached: [ChatArtifactIndexedReference],
        referenced: [ChatArtifactIndexedReference]
    ) {
        let stableItems = orderedItems ?? ChatArtifactGalleryOrdering().sorted(items)
        return (
            created: stableItems.filter { $0.provenance == .created },
            attached: stableItems.filter { $0.provenance == .attached },
            referenced: stableItems.filter { $0.provenance == .referenced }
        )
    }

    private func row(
        for reference: ChatArtifactIndexedReference,
        includeDirectories: Bool,
        includeMissing: Bool
    ) -> ChatArtifactGalleryItem? {
        // One stat outcome drives BOTH the inclusion decision and the row
        // payload, so what renders cannot diverge from the shared rule and
        // there is no second stat (and no window for the file to change
        // between decision and construction).
        let reader = ArtifactByteReader()
        do {
            let stat = try reader.stat(path: reference.path)
            guard Self.isRowIncluded(
                exists: stat.exists,
                isDirectory: stat.isDirectory,
                includeDirectories: includeDirectories,
                includeMissing: includeMissing
            ) else { return nil }
            let children = stat.isDirectory ? directoryChildCount(path: reference.path) : nil
            return ChatArtifactGalleryItem(
                path: reference.path,
                kind: stat.kind,
                displayName: URL(fileURLWithPath: reference.path).lastPathComponent,
                size: stat.size,
                modifiedAt: stat.modifiedAt,
                exists: stat.exists,
                childCount: children?.count,
                childCountIsCapped: children?.isCapped ?? false,
                provenance: reference.provenance
            )
        } catch {
            guard Self.isRowIncluded(
                exists: false,
                isDirectory: false,
                includeDirectories: includeDirectories,
                includeMissing: includeMissing
            ) else { return nil }
            return ChatArtifactGalleryItem(
                path: reference.path,
                kind: reader.kind(path: reference.path, isDirectory: false),
                displayName: URL(fileURLWithPath: reference.path).lastPathComponent,
                exists: false,
                provenance: reference.provenance
            )
        }
    }

    /// Counts immediate children for a gallery directory row without sorting
    /// or per-entry metadata, stopping at the shared listing limit so the cost
    /// never scales past the cap for large folders.
    private func directoryChildCount(path: String) -> (count: Int, isCapped: Bool)? {
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: [],
            options: [.skipsSubdirectoryDescendants]
        ) else {
            return nil
        }
        var count = 0
        while enumerator.nextObject() != nil {
            count += 1
            if count > ArtifactByteReader.maximumDirectoryEntryCount {
                return (count: ArtifactByteReader.maximumDirectoryEntryCount, isCapped: true)
            }
        }
        return (count: count, isCapped: false)
    }
}
