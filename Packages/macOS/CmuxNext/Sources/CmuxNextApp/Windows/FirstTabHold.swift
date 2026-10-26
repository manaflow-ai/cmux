
/// A new workspace that opens on the New Tab page (Cmd-N) joins its window
/// once its first tab is there, so the window changes in one step: its row
/// in the sidebar, its tab and the page together (bd cx-8g3sn). The daemon
/// creates the workspace and its first tab with two requests; shown at the
/// first, the window drew an empty workspace (a blank content area) and
/// then the page.
///
/// While it waits, reconcile leaves the workspace unowned and keeps its
/// claim (`WindowManager.reconcileMembership`); the release reconciles
/// again, which places and selects it.
@MainActor
enum FirstTabHold {
    /// A first tab that never shows (a failed request the daemon did not
    /// report) does not keep the workspace out of its window longer.
    static let limit: Duration = .seconds(2)
    private static var waiting: Set<String> = []

    /// The ones of `live` that wait for their first tab.
    static func held(_ live: [String]) -> Set<String> {
        waiting.isEmpty ? [] : Set(live.filter(waiting.contains))
    }

    /// Runs `create` (the workspace and its first tab) with workspace `id`
    /// held, and releases it once the store lists that tab; nil from
    /// `create` (no New Tab page) releases it at once.
    static func creating<T>(_ id: String, windows: WindowManager, _ create: () async throws -> T?) async throws -> T? {
        waiting.insert(id)
        let created: T?
        do {
            created = try await create()
        } catch {
            release(id, windows)
            throw error
        }
        if created != nil { await firstTab(of: id, windows.services) }
        release(id, windows)
        return created
    }

    private static func release(_ id: String, _ windows: WindowManager) {
        guard waiting.remove(id) != nil else { return }
        windows.reconcileMembership()
        // The page shows in its window now: keys held since Cmd-N may go to its field.
        windows.services.keyRouter.newTabInputCoordinator.flushAll()
    }

    /// Returns once workspace `id` has a tab in the store, or after ``limit``.
    private static func firstTab(of id: String, _ services: AppServices) async {
        await ObservedCondition(owner: "FirstTabHold.firstTab", .visible, on: services.mainWork)
            .until(timeout: limit, deadlines: services.mainDeadlines) { [weak services] in
                services?.workspace(id: id).map { !$0.screens.flatMap(\.panes).flatMap(\.tabs).isEmpty } ?? true
            }
    }
}
