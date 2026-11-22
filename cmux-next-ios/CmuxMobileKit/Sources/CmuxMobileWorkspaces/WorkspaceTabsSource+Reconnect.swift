#if os(iOS)
import CmuxMobileModel
import Foundation

/// A link drop and relink can publish a workspace with tabs missing for a few seconds
/// (`AppStore.replaceWorkspaces`), and `macConnection` goes connected, connecting, connected.
/// State the person set survives that: it goes only when they changed it, or the thing stays
/// missing on a connected Mac past this grace.
extension WorkspaceTabsSource {
    static let reconnectGrace: Duration = .seconds(10)

    /// The workspace's Mac has a link up (or the app tracks no links, as in mock data).
    var macLinkUp: Bool {
        guard let macID = workspace?.macID, let connection = store.macConnection[macID] else { return true }
        return connection == .connected
    }

    /// Whether tab group `id` is really gone: empty on a connected Mac, and still so after the
    /// grace (at once when this phone's own edit emptied it). False when the group came back, the
    /// link is down or coming back, or the caller's task was cancelled.
    func groupStaysGone(_ id: String) async -> Bool {
        guard members(ofGroup: id).isEmpty, macLinkUp else { return false }
        if groupsEmptiedHere.contains(id) { return true }
        do { try await clock.sleep(for: Self.reconnectGrace) } catch { return false }
        return members(ofGroup: id).isEmpty && macLinkUp
    }
}
#endif
