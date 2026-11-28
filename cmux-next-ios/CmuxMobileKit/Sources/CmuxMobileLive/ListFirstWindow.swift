import CmuxMobileModel
import Foundation

/// The phone's first window of a Mac's workspaces (`list-workspaces-page-v1`): the setup batch
/// asks for the first `limit` workspaces in sidebar order (a page the Mac also bounds at 64 KiB
/// of rows), so the first Home and Workspaces content costs the same at 10, 100 and 1,000
/// workspaces. The whole tree follows in the background (`WorkspaceSync.refresh`).
///
/// The setup batch goes out before `identify` answers, and a Mac lane older than this field
/// may refuse a field it does not know, so the phone asks for the window only from a Mac whose
/// last `identify` advertised it. The first connect to a Mac sends today's batch. A Mac that
/// also advertised `list-workspaces-slim-v1` is asked for slim rows (`rows: "slim"`).
enum ListFirstWindow {
    /// The daemon's capability (cmux-tui `LIST_WORKSPACES_PAGE_CAPABILITY`).
    nonisolated static let capability = "list-workspaces-page-v1"
    /// The workspaces the first window asks for: more than a phone screen shows.
    nonisolated static let limit = 40
    /// The daemon's capability for slim rows (cmux-tui `LIST_WORKSPACES_SLIM_CAPABILITY`): a
    /// first window whose rows carry only what Home and the Workspaces list draw, so it holds
    /// every row it asks for.
    nonisolated static let slimCapability = "list-workspaces-slim-v1"
    nonisolated static let defaultsKey = "cmux.mobile.listFirstWindowMacs"
    nonisolated static let slimDefaultsKey = "cmux.mobile.listSlimRowsMacs"

    /// Whether the Mac `macID` advertised the window at its last `identify`.
    nonisolated static func honors(_ macID: String?, defaults: UserDefaults) -> Bool {
        noted(macID, key: defaultsKey, defaults: defaults)
    }

    /// Whether the Mac `macID` advertised slim rows at its last `identify`.
    nonisolated static func honorsSlim(_ macID: String?, defaults: UserDefaults) -> Bool {
        noted(macID, key: slimDefaultsKey, defaults: defaults)
    }

    /// Records what the Mac's `identify` advertised.
    nonisolated static func note(_ macID: String, honors: Bool, slim: Bool = false, defaults: UserDefaults) {
        note(macID, honors, key: defaultsKey, defaults: defaults)
        note(macID, honors && slim, key: slimDefaultsKey, defaults: defaults)
    }

    private nonisolated static func noted(_ macID: String?, key: String, defaults: UserDefaults) -> Bool {
        guard let macID, !macID.isEmpty else { return false }
        return (defaults.stringArray(forKey: key) ?? []).contains(macID)
    }

    private nonisolated static func note(_ macID: String, _ honors: Bool, key: String, defaults: UserDefaults) {
        guard !macID.isEmpty else { return }
        var macs = defaults.stringArray(forKey: key) ?? []
        guard macs.contains(macID) != honors else { return }
        if honors { macs.append(macID) } else { macs.removeAll { $0 == macID } }
        // A phone pairs few Macs; keep the most recent few.
        defaults.set(Array(macs.suffix(16)), forKey: key)
    }

    /// The setup batch's `list-workspaces` params: slim rows only from a Mac that advertised them.
    nonisolated static func params(honors: Bool, slim: Bool = false) -> [String: Any] {
        guard honors else { return [:] }
        return slim ? ["limit": limit, "rows": "slim"] : ["limit": limit]
    }

    /// Whether a `list-workspaces` reply is a page that leaves workspaces out (`total` past
    /// the rows it holds) or whose rows are slim (`rows: "slim"`). A whole tree has neither.
    nonisolated static func isPartial(_ reply: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { return false }
        let data = object["data"] as? [String: Any] ?? object
        if data["rows"] as? String == "slim" { return true }
        guard let total = data["total"] as? Int, let rows = data["workspaces"] as? [Any] else { return false }
        return rows.count < total
    }

    /// A first window drawn over what the phone already held for this Mac: the page's rows
    /// first, then the kept rows the page does not hold, so the list does not shrink to the
    /// page while the whole tree is on its way. A slim row carries no layout; it keeps the
    /// held row's layout and screens until the whole tree replaces them.
    nonisolated static func drawn(_ page: DaemonTree, keeping kept: [Workspace]) -> DaemonTree {
        let onPage = Set(page.workspaces.map(\.id)).union(page.homeWorkspaces.map(\.id))
        let held = Dictionary(kept.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var drawn = page
        for index in drawn.workspaces.indices where drawn.workspaces[index].layout == nil {
            guard let old = held[drawn.workspaces[index].id] else { continue }
            drawn.workspaces[index].layout = old.layout
            if !old.screens.isEmpty { drawn.workspaces[index].screens = old.screens }
        }
        drawn.workspaces += kept.filter { !onPage.contains($0.id) }
        return drawn
    }
}
