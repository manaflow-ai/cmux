/// Restored recent items and the byte cursor for history that remains on disk.
struct WorkstreamStartupSnapshot: Sendable {
    let items: [WorkstreamItem]
    let revision: Int
    let page: WorkstreamPersistence.Page
    let diagnostics: WorkstreamStartupDiagnostics
}
