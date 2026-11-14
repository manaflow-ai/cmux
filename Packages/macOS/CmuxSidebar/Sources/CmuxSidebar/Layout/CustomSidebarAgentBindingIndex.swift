public import Foundation

/// Agent-session records grouped by the terminal panel or workspace they are
/// bound to, so each workspace's `workspaces[i].agents` can be projected
/// without rescanning every record.
///
/// The custom-sidebar data context is rebuilt on every sidebar tick, once a
/// second, for every workspace. Fetching, sorting and scanning the whole
/// session registry once per workspace made that build
/// O(workspaces × records log records): with about 100 workspaces and about
/// 1,000 records it held the main thread for roughly 400 ms every second.
/// Build one index per data-context build from the registry's records and look
/// each workspace up in it instead.
///
/// A lookup returns exactly what a front-to-back scan of the input would keep:
/// records bound to one of the workspace's panels, plus records without a panel
/// binding whose stored workspace id matches, in input order, at most `limit`.
/// A record bound to a panel outside the workspace is left out even when its
/// stored workspace id matches, because the panel binding is authoritative.
///
/// ```swift
/// let index = CustomSidebarAgentBindingIndex(records: service.sessionRecords(workspaceID: nil)) { record in
///     if let panelId = record.surfaceID.flatMap(UUID.init(uuidString:)) {
///         return .panel(panelId)
///     }
///     return record.workspaceID.map { .workspace($0) } ?? .unbound
/// }
/// let agents = index.records(panelIds: livePanelIds, workspaceId: workspace.id.uuidString, limit: 24)
/// ```
public struct CustomSidebarAgentBindingIndex<Record> {
    /// What one record is bound to.
    public enum Binding: Hashable, Sendable {
        /// A terminal panel: the record belongs to whichever workspace hosts it.
        case panel(UUID)
        /// No panel binding: the record falls back to this stored workspace id.
        case workspace(String)
        /// Neither: the record never appears in a lookup.
        case unbound
    }

    /// One record a lookup kept, with the panel it is bound to, if any.
    public struct Match {
        /// The record.
        public let record: Record
        /// The panel the record is bound to, or `nil` for a workspace fallback.
        public let panelId: UUID?
    }

    fileprivate struct Entry {
        let rank: Int
        let record: Record
        let panelId: UUID?
    }

    private var recordsByPanelId: [UUID: [Entry]] = [:]
    private var recordsByWorkspaceId: [String: [Entry]] = [:]

    /// An index that holds no records.
    public init() {}

    /// Indexes records in the order lookups should return them.
    ///
    /// - Parameters:
    ///   - records: The records, highest priority first (the session registry
    ///     returns most recent activity first).
    ///   - binding: What each record is bound to. Called once per record.
    public init(records: [Record], binding: (Record) -> Binding) {
        for (rank, record) in records.enumerated() {
            switch binding(record) {
            case let .panel(panelId):
                recordsByPanelId[panelId, default: []]
                    .append(Entry(rank: rank, record: record, panelId: panelId))
            case let .workspace(workspaceId):
                recordsByWorkspaceId[workspaceId, default: []]
                    .append(Entry(rank: rank, record: record, panelId: nil))
            case .unbound:
                continue
            }
        }
    }

    /// The records one workspace shows.
    ///
    /// - Parameters:
    ///   - panelIds: The workspace's live terminal panels, each listed once.
    ///   - workspaceId: The workspace's id string, matched against records
    ///     that have no panel binding.
    ///   - limit: The most records to return.
    /// - Returns: The matching records in input order, at most `limit`.
    public func records(
        panelIds: some Sequence<UUID>,
        workspaceId: String,
        limit: Int
    ) -> [Match] {
        guard limit > 0 else { return [] }
        var entries = recordsByWorkspaceId[workspaceId] ?? []
        for panelId in panelIds {
            if let bound = recordsByPanelId[panelId] {
                entries.append(contentsOf: bound)
            }
        }
        entries.sort { $0.rank < $1.rank }
        return entries.prefix(limit).map { Match(record: $0.record, panelId: $0.panelId) }
    }
}

extension CustomSidebarAgentBindingIndex: Sendable where Record: Sendable {}
extension CustomSidebarAgentBindingIndex.Match: Sendable where Record: Sendable {}
extension CustomSidebarAgentBindingIndex.Entry: Sendable where Record: Sendable {}
