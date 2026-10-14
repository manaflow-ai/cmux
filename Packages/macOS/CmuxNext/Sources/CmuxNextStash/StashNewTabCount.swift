import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDaemonService

/// The New Tab page's Stashed link: every page hears how many tabs are stashed (none, or a
/// daemon without stash-v1: no link), again when the count or the set of pages changes. The
/// stashes are read once this Mac's daemon serves them, and again on each stash change it
/// publishes on `session.events` (the CLI, MCP, another window).
public enum StashNewTabCount {
    public static func wire(_ stash: StashService, host: any StashHost) {
        // task-owner: lives as long as the host; ends when it goes.
        Task { [weak host, weak stash] in
            var last: Int?
            let changes = ObservationStream { [weak host, weak stash] () -> Int? in
                guard let host, let stash, stash.serves(host.localDaemon) else { return nil }
                return host.localDaemon.store.session.mirror?.stashChanges ?? 0
            }
            for await change in changes where change != last {
                last = change
                if change != nil { await stash?.model.reload() }
            }
        }
        // task-owner: lives as long as the host; ends when it goes.
        Task { [weak host, weak stash] in
            var last: [String] = []
            let keys = ObservationStream { [weak host, weak stash] in
                guard let host, let stash else { return [String]() }
                let count = stash.serves(host.localDaemon) ? stash.model.tabCount : 0
                return [String(count)] + host.stashCountPages.keys.sorted()
            }
            for await key in keys where key != last {
                guard let host, let first = key.first else { return }
                last = key
                for view in Array(host.stashCountPages.values) + host.stashCountStandalonePages {
                    AgentPageEvent.pushStashedCount(Int(first) ?? 0, to: view)
                }
            }
        }
    }
}
