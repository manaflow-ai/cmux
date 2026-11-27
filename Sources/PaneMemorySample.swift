import Foundation

/// Result of summing a pane's process-tree memory off the main thread.
struct PaneMemorySample: Sendable {
    let descriptor: PaneMemoryDescriptor
    /// Physical-footprint bytes summed across every process sharing the pane's
    /// controlling tty. This is what macOS aggregates for "out of application
    /// memory", so it is the signal the threshold is compared against.
    let memoryBytes: Int64
    /// Resident bytes summed across the same process set (informational).
    let residentBytes: Int64
    /// Process-group ids that contribute enough memory to clear this pane's warning.
    let memoryPressureProcessGroupIDs: [Int]
    let foregroundCommand: String?

    var key: PaneMemoryPaneKey { descriptor.key }

    var warning: PaneMemoryWarning {
        PaneMemoryWarning(
            workspaceId: descriptor.workspaceId,
            panelId: descriptor.panelId,
            workspaceTitle: descriptor.workspaceTitle,
            paneTitle: descriptor.paneTitle,
            memoryBytes: memoryBytes,
            foregroundCommand: foregroundCommand
        )
    }
}
