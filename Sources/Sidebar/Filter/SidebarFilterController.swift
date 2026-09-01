import CmuxSidebar
import CmuxWorkspaces
import Combine
import Foundation

/// Owns the sidebar filter for one window: the query, the prepared index, and
/// the outcome the row projection reads.
///
/// The index is rebuilt only when the searchable text actually changes, keyed
/// by ``SidebarFilterCorpusKey``. Everything else (scoring, group expansion,
/// highlight offsets) is pure logic in `CmuxSidebar`; this type is the cache
/// and the published surface around it.
@MainActor
final class SidebarFilterController: ObservableObject {
    /// The text in the filter field.
    @Published var queryText: String = "" {
        didSet {
            guard queryText != oldValue else { return }
            recomputeOutcome()
        }
    }

    /// Whether the filter field is mounted.
    ///
    /// Separate from `queryText` being empty: the field can be open and empty,
    /// which shows every row but keeps focus for the next keystroke.
    @Published private(set) var isFieldPresented = false

    /// The current filter result. ``SidebarFilterOutcome/inactive`` when off.
    @Published private(set) var outcome: SidebarFilterOutcome = .inactive

    private var index: SidebarFilterIndex?
    private var corpusKey: SidebarFilterCorpusKey?
    private var totalWorkspaceCount = 0

    /// The snapshot the filter field renders from.
    var fieldModel: SidebarFilterFieldModel {
        SidebarFilterFieldModel(
            queryText: queryText,
            matchCount: outcome.isFiltering ? outcome.orderedMatchWorkspaceIds.count : totalWorkspaceCount,
            totalCount: totalWorkspaceCount,
            scopeField: SidebarFilterQuery(queryText).restrictedField
        )
    }

    /// Opens the field and focuses it.
    func presentField() {
        isFieldPresented = true
    }

    /// Closes the field and clears the query.
    ///
    /// Clearing on dismiss is deliberate: a filter left applied behind a hidden
    /// field is a sidebar that is silently lying about how many workspaces
    /// exist.
    func dismissField() {
        isFieldPresented = false
        if !queryText.isEmpty {
            queryText = ""
        }
    }

    /// Rebuilds the prepared index if the searchable text changed.
    ///
    /// Called from the sidebar's render-context construction, which runs on
    /// every sidebar invalidation; the corpus key is what keeps that cheap.
    ///
    /// - Parameters:
    ///   - entries: Searchable text per workspace, in sidebar order.
    ///   - groups: The workspace groups.
    func updateCorpus(entries: [SidebarFilterCorpusEntry], groups: [WorkspaceGroup]) {
        totalWorkspaceCount = entries.count
        let key = SidebarFilterCorpusKey(entries: entries, groups: groups)
        guard key != corpusKey else { return }
        corpusKey = key
        index = SidebarFilterIndex(
            candidates: entries.map(Self.candidate(from:)),
            groups: groups.map {
                SidebarFilterGroup(
                    id: $0.id,
                    anchorWorkspaceId: $0.anchorWorkspaceId,
                    name: $0.name
                )
            }
        )
        recomputeOutcome()
    }

    private func recomputeOutcome() {
        guard let index, isFieldPresented else {
            if outcome.isFiltering { outcome = .inactive }
            return
        }
        let next = index.outcome(for: SidebarFilterQuery(queryText))
        // Republishing an equal outcome would invalidate the sidebar on every
        // keystroke that changes nothing, such as typing into an already-empty
        // result.
        guard next != outcome else { return }
        outcome = next
    }

    private static func candidate(
        from entry: SidebarFilterCorpusEntry
    ) -> SidebarFilterCandidate {
        var fields: [SidebarFilterCandidateField] = [
            SidebarFilterCandidateField(field: .title, displayText: entry.title)
        ]
        if let branch = entry.branch, !branch.isEmpty {
            fields.append(SidebarFilterCandidateField(field: .branch, displayText: branch))
        }
        if let directory = entry.directory, !directory.isEmpty {
            fields.append(SidebarFilterCandidateField(field: .directory, displayText: directory))
        }
        if let pullRequest = entry.pullRequest, !pullRequest.isEmpty {
            fields.append(
                SidebarFilterCandidateField(field: .pullRequest, displayText: pullRequest)
            )
        }
        for port in entry.ports where !port.isEmpty {
            fields.append(SidebarFilterCandidateField(field: .port, displayText: port))
        }
        return SidebarFilterCandidate(
            id: entry.workspaceId,
            groupId: entry.groupId,
            isGroupAnchor: entry.isGroupAnchor,
            fields: fields
        )
    }
}
