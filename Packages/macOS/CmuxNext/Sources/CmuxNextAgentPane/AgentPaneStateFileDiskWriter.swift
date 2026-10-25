import CmuxNextCompat
import Foundation

/// Writes agent pane state files to disk through the checked blocking seams, so a write that runs
/// on the main thread again is reported by the blocking detector (plans/cmux-next/threading-model.md).
nonisolated struct AgentPaneStateFileDiskWriter: AgentPaneStateFileWriting {
    func write(_ data: Data, to url: URL) {
        try? data.blockingWrite(to: url, options: .atomic)
    }

    func remove(_ url: URL) {
        try? FileManager.checked.removeItem(at: url)
    }
}
