#if DEBUG && os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import Foundation
import UIKit

/// Plays `HostLoadSim.heavy` into the store: the workspace pushes a busy Mac
/// sends (`LiveCoordinator`'s `onRows` and `onTree`), at 20 Hz, while the
/// person types, from the first keyboard on. Mock sessions take the `tick` it
/// posts. Runs until the app ends; idle and cut send nothing from here.
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
        // From the first keyboard on: a push that moves the list's rows while the test
        // taps one opens another workspace (rows sort by activity).
        for await _ in NotificationCenter.default.notifications(named: UIResponder.keyboardWillShowNotification) { break }
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
            // Once a second, a slow Mac's backlog: ten pushes in one turn.
            let burst = tick % 20 == 19 ? 10 : 1
            // PushApplyTrace: the turn's sync cost, its whole run-loop iteration and
            // its commit, and (a burst) its start to the next presented frame.
            if burst > 1 {
                PushApplyTrace.tagIteration("push_burst")
                PushApplyTrace.toNextFrame("push_burst_to_frame")
                PushApplyTrace.measure("push_burst_sync") {
                    for _ in 0..<burst {
                        tick += 1
                        push(tick: tick, store: store)
                    }
                }
            } else {
                PushApplyTrace.tagIteration("push_tick")
                PushApplyTrace.measure("push_tick_sync") {
                    tick += 1
                    push(tick: tick, store: store)
                }
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
                PushApplyTrace.measure("push_apply_tree") { store.replaceWorkspaces(macID: macID, with: rows) }
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
            for (macID, rows) in byMac {
                PushApplyTrace.measure("push_apply_rows") { store.updateWorkspaces(macID: macID, rows: rows) }
            }
        }
        // The mock terminal's status line (`push_apply_status`) and chat status
        // (`push_apply_chat`, applied later by the chat store's task) hang off this.
        PushApplyTrace.measure("push_apply_tick_post") {
            NotificationCenter.default.post(name: HostLoadSim.tick, object: tick)
        }
    }
}
#endif
