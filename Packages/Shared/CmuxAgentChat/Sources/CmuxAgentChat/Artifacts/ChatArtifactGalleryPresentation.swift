import Foundation

/// A pure sheet-wide filter and sort projection over fixed gallery groups.
public struct ChatArtifactGalleryPresentation: Sendable, Equatable {
    /// Created, Attached, and Referenced groups in their fixed display order.
    public let groups: [ChatArtifactGalleryGroup]

    /// Whether every projected group has no visible rows.
    public var isEmpty: Bool { groups.allSatisfy(\.items.isEmpty) }

    /// Creates a grouped presentation without changing the source snapshot.
    ///
    /// - Parameters:
    ///   - snapshot: Accumulated gallery rows to project.
    ///   - filter: Sheet-wide kind filter.
    ///   - sort: Ordering applied independently within each group.
    ///   - includesMissingFiles: Whether rows absent from the Mac remain visible.
    ///   - classifier: Classifier used for extension-based buckets.
    public init(
        snapshot: ChatArtifactGallerySnapshot,
        filter: ChatArtifactGalleryFilter = .all,
        sort: ChatArtifactGallerySort = .recent,
        includesMissingFiles: Bool = false,
        classifier: ChatArtifactGalleryClassifier = ChatArtifactGalleryClassifier()
    ) {
        groups = [
            ChatArtifactGalleryGroup(
                kind: .created,
                items: Self.project(
                    snapshot.created,
                    filter: filter,
                    sort: sort,
                    includesMissingFiles: includesMissingFiles,
                    classifier: classifier
                )
            ),
            ChatArtifactGalleryGroup(
                kind: .attached,
                items: Self.project(
                    snapshot.attached,
                    filter: filter,
                    sort: sort,
                    includesMissingFiles: includesMissingFiles,
                    classifier: classifier
                )
            ),
            ChatArtifactGalleryGroup(
                kind: .referenced,
                items: Self.project(
                    snapshot.referenced,
                    filter: filter,
                    sort: sort,
                    includesMissingFiles: includesMissingFiles,
                    classifier: classifier
                )
            ),
        ]
    }

    /// Returns the visible rows for one fixed group.
    ///
    /// - Parameter kind: Group whose projected rows are needed.
    /// - Returns: Visible rows, or an empty array when the group is absent.
    public func items(in kind: ChatArtifactGalleryGroupKind) -> [ChatArtifactGalleryItem] {
        groups.first { $0.kind == kind }?.items ?? []
    }

    private static func project(
        _ items: [ChatArtifactGalleryItem],
        filter: ChatArtifactGalleryFilter,
        sort: ChatArtifactGallerySort,
        includesMissingFiles: Bool,
        classifier: ChatArtifactGalleryClassifier
    ) -> [ChatArtifactGalleryItem] {
        let visible = includesMissingFiles ? items : items.filter(\.exists)
        let filtered = filter == .all
            ? visible
            : visible.filter { classifier.filter(for: $0) == filter }
        switch sort {
        case .recent:
            return filtered
        case .name:
            return filtered.enumerated().sorted { lhs, rhs in
                let comparison = lhs.element.displayName.localizedCaseInsensitiveCompare(
                    rhs.element.displayName
                )
                return comparison == .orderedSame
                    ? lhs.offset < rhs.offset
                    : comparison == .orderedAscending
            }.map(\.element)
        case .size:
            return filtered.enumerated().sorted { lhs, rhs in
                switch (lhs.element.size, rhs.element.size) {
                case let (left?, right?) where left != right:
                    return left > right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.offset < rhs.offset
                }
            }.map(\.element)
        }
    }
}
