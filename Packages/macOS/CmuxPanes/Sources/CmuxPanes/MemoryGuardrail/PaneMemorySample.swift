public import Foundation

/// Result of summing a pane's process-tree memory off the main thread.
public struct PaneMemorySample: Sendable {
    public let descriptor: PaneMemoryDescriptor
    /// Physical-footprint bytes summed across every process sharing the pane's
    /// controlling tty. This is what macOS aggregates for "out of application
    /// memory", so it is the signal the threshold is compared against.
    public let memoryBytes: Int64
    /// Resident bytes summed across the same process set (informational).
    public let residentBytes: Int64
    /// Process-group ids that contribute enough memory to clear this pane's warning.
    public let memoryPressureProcessGroupIDs: [Int]
    public let foregroundCommand: String?

    public init(
        descriptor: PaneMemoryDescriptor,
        memoryBytes: Int64,
        residentBytes: Int64,
        memoryPressureProcessGroupIDs: [Int],
        foregroundCommand: String?
    ) {
        self.descriptor = descriptor
        self.memoryBytes = memoryBytes
        self.residentBytes = residentBytes
        self.memoryPressureProcessGroupIDs = memoryPressureProcessGroupIDs
        self.foregroundCommand = foregroundCommand
    }

    public var key: PaneMemoryPaneKey { descriptor.key }

    public var warning: PaneMemoryWarning {
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
