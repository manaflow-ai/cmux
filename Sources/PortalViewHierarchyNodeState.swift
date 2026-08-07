import AppKit

/// Cache-miss split-presence index associated directly with one AppKit view.
@MainActor
final class PortalViewHierarchyNodeState: NSObject {
    weak var tracker: PortalViewHierarchyMutationTracker?
    var generation: UInt64 = 0
    var containsSplitView = false
}
