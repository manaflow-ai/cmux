import CmuxNextCompat
import CmuxNextDaemon
import os

/// A tab the store just created, once its tree has it. The creation reply can come before the
/// tree mirrors the tab, and an action on the tab then is refused ("no tab"): [+] New tab's page
/// stayed in the chat's pane because its move ran in that gap (cx-65br).
enum TabMirror {
    typealias Locate = @MainActor (String) -> (pane: PaneID, daemon: DaemonService)?
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.tab-mirror")

    /// A creation reply is not yet a usable placement target until its tree has the tab.
    @MainActor static func performWhenReached(_ key: String, in locate: @escaping Locate, perform: @MainActor () -> Void) async {
        guard await reaches(key, in: locate), !Task.isCancelled else { return }
        perform()
    }

    /// Whether `locate` finds tab `key` within 10 s (at once when it already does); logs when not.
    static func reaches(_ key: String, in locate: @escaping Locate) async -> Bool {
        if locate(key) != nil { return true }
        // concurrency-allow: the observation task exits on cancellation; this bounds a daemon mirror race
        let reached = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await waitFor(key, locate: locate) }
            group.addTask {
                // wakeup-allow: one-shot ten-second daemon mirror deadline
                try? await Task.sleep(for: .seconds(10))
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
        if !reached { logger.error("tab \(key, privacy: .public) did not reach the store's tree within 10 s") }
        return reached
    }

    private static func waitFor(_ key: String, locate: @escaping Locate) async -> Bool {
        for await found in ObservationStream({ locate(key) != nil }) where found { return true }
        return false
    }
}
