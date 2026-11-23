import CmuxMobileModel
import Foundation

/// The phone's first window of a Mac's workspaces (`list-workspaces-page-v1`): the setup batch
/// asks for the first `limit` workspaces in sidebar order (a page the Mac also bounds at 64 KiB
/// of rows), so the first Home and Workspaces content costs the same at 10, 100 and 1,000
/// workspaces. The whole tree follows in the background (`WorkspaceSync.refresh`).
///
/// The setup batch goes out before `identify` answers, and a Mac lane older than this field
/// may refuse a field it does not know, so the phone asks for the window only from a Mac whose
/// last `identify` advertised it. The first connect to a Mac sends today's batch.
enum ListFirstWindow {
    /// The daemon's capability (cmux-tui `LIST_WORKSPACES_PAGE_CAPABILITY`).
    nonisolated static let capability = "list-workspaces-page-v1"
    /// The workspaces the first window asks for: more than a phone screen shows.
    nonisolated static let limit = 40
    nonisolated static let defaultsKey = "cmux.mobile.listFirstWindowMacs"

    /// Whether the Mac `macID` advertised the window at its last `identify`.
    nonisolated static func honors(_ macID: String?, defaults: UserDefaults) -> Bool {
        guard let macID, !macID.isEmpty else { return false }
        return (defaults.stringArray(forKey: defaultsKey) ?? []).contains(macID)
    }

    /// Records what the Mac's `identify` advertised.
    nonisolated static func note(_ macID: String, honors: Bool, defaults: UserDefaults) {
        guard !macID.isEmpty else { return }
        var macs = defaults.stringArray(forKey: defaultsKey) ?? []
        guard macs.contains(macID) != honors else { return }
        if honors { macs.append(macID) } else { macs.removeAll { $0 == macID } }
        // A phone pairs few Macs; keep the most recent few.
        defaults.set(Array(macs.suffix(16)), forKey: defaultsKey)
    }

    /// The setup batch's `list-workspaces` params.
    nonisolated static func params(honors: Bool) -> [String: Any] {
        honors ? ["limit": limit] : [:]
    }

    /// Whether a `list-workspaces` reply is a page that leaves workspaces out (`total` past
    /// the rows it holds). A whole tree has no `total`.
    nonisolated static func isPartial(_ reply: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { return false }
        let data = object["data"] as? [String: Any] ?? object
        guard let total = data["total"] as? Int, let rows = data["workspaces"] as? [Any] else { return false }
        return rows.count < total
    }

    /// A first window drawn over what the phone already held for this Mac: the page's rows
    /// first, then the kept rows the page does not hold, so the list does not shrink to the
    /// page while the whole tree is on its way.
    nonisolated static func drawn(_ page: DaemonTree, keeping kept: [Workspace]) -> DaemonTree {
        let onPage = Set(page.workspaces.map(\.id)).union(page.homeWorkspaces.map(\.id))
        var drawn = page
        drawn.workspaces += kept.filter { !onPage.contains($0.id) }
        return drawn
    }
}
