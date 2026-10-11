import CmuxNextCompat
import CmuxNextDaemon

/// A tab the store just created, once its tree has it. The creation reply can come before the
/// tree mirrors the tab, and an action on the tab then is refused ("no tab"): [+] New tab's page
/// stayed in the chat's pane because its move ran in that gap (cx-65br).
enum TabMirror {
    typealias Locate = @MainActor (String) -> (pane: PaneID, daemon: DaemonService)?

    /// Whether `locate` finds tab `key` within 10 s (at once when it already does).
    static func reaches(_ key: String, in locate: @escaping Locate) async -> Bool {
        if locate(key) != nil { return true }
        // concurrency-allow: the observation task exits on cancellation; this bounds a daemon mirror race
        return await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await waitFor(key, locate: locate) }
            group.addTask {
                // wakeup-allow: one-shot ten-second daemon mirror deadline
                try? await Task.sleep(for: .seconds(10))
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
    }

    private static func waitFor(_ key: String, locate: @escaping Locate) async -> Bool {
        for await found in ObservationStream({ locate(key) != nil }) where found { return true }
        return false
    }
}
