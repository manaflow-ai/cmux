/// Persisted state for a ``HistoryPanel``. The pane's grouping and scope are read
/// from user defaults via ``SessionIndexStore``, so the snapshot only needs to
/// record that a history pane existed; its presence drives restore.
struct SessionHistoryPanelSnapshot: Codable, Sendable {
    init() {}
}
