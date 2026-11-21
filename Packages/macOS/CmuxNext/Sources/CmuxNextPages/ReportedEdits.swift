/// A file tab's edits its page reported that no save has covered yet (app health's hold, #39247). A save
/// covers them only when no report came while it ran: edit reports coalesce, so a newer edit may still
/// wait in one, and the page's own mark (`[data-cmux-unsaved-edits]`, ``PageWebView/reportsUnsavedEdits``)
/// holds that one until its text is on disk.
@MainActor
public final class ReportedEdits {
    /// The page reported an edit no save has covered yet.
    public private(set) var held = false
    private var reports = 0

    public init() {}

    /// The page reported an edit.
    public func reported() {
        held = true
        reports &+= 1
    }

    /// Runs `save`; once it succeeds with no report while it ran, the reported edits are covered.
    public func covering<T, E: Error>(_ save: () async throws(E) -> T) async throws(E) -> T {
        let before = reports
        let result = try await save()
        if reports == before { held = false }
        return result
    }
}
