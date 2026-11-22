#if DEBUG
import CmuxMobileDesign
import CmuxMobileModel
import Foundation

/// Plays `HostLoadSim.heavy` into the store: the workspace pushes a busy Mac
/// sends (`LiveCoordinator`'s `onRows` and `onTree`), at 20 Hz, while the
/// person types. Mock sessions take the `tick` it posts. Runs until the app
/// ends; idle and cut send nothing from here.
@MainActor
enum HostLoadDriver {
    static func runIfConfigured(store: AppStore) async {
        switch HostLoadSim.mode {
        case .idle: return
        case .cut:
            NotificationCenter.default.post(name: HostLoadSim.cut, object: nil)
            return
        case .heavy: break
        }
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
            // Once a second, a slow Mac's backlog: ten pushes in one turn.
            let burst = tick % 20 == 19 ? 10 : 1
            for _ in 0..<burst {
                tick += 1
                push(tick: tick, store: store)
            }
        }
    }

    private static func push(tick: Int, store: AppStore) {
        let all = store.workspaces
        guard !all.isEmpty else { return }
        let now = Date()
        if tick % 20 == 0 {
            // The whole tree, every row's activity moved (a Mac's `onTree`).
            for macID in Set(all.map(\.macID)) {
                let rows = all.filter { $0.macID == macID }.map { row -> Workspace in
                    var row = row
                    row.lastActivityAt = now
                    return row
                }
                store.replaceWorkspaces(macID: macID, with: rows)
            }
        } else {
            // Eight rows' metadata (a Mac's `onRows`), round robin.
            let start = (tick * 8) % all.count
            var byMac: [String: [Workspace]] = [:]
            for offset in 0..<min(8, all.count) {
                var row = all[(start + offset) % all.count]
                row.lastActivityAt = now
                row.isWorking = tick % 2 == 0
                byMac[row.macID, default: []].append(row)
            }
            for (macID, rows) in byMac { store.updateWorkspaces(macID: macID, rows: rows) }
        }
        NotificationCenter.default.post(name: HostLoadSim.tick, object: tick)
    }
}
#endif
