import Foundation

enum SidebarProfilingSignposts {
    private static let signposts = DynamicTracingSignposts(subsystem: "com.cmux.sidebar")
    @MainActor private static var selectionLatency: (
        workspaceID: UUID,
        interval: DynamicTracingSignpostInterval
    )?

    @inline(__always)
    static func begin(_ name: StaticString, _ message: @autoclosure () -> String) -> DynamicTracingSignpostInterval? {
        signposts.begin(name, message())
    }

    @inline(__always)
    static func end(_ interval: DynamicTracingSignpostInterval?) {
        signposts.end(interval)
    }

    @MainActor
    static func beginSelectionLatency(workspaceID: UUID) {
        if let pending = selectionLatency {
            signposts.end(pending.interval)
        }
        selectionLatency = signposts.begin(
            "sidebar-selection-event-to-visible-state",
            "workspace=\(workspaceID.uuidString)"
        ).map { (workspaceID, $0) }
    }

    @MainActor
    static func endSelectionLatencyIfVisible(workspaceID: UUID, isSelected: Bool) {
        guard isSelected,
              let pending = selectionLatency,
              pending.workspaceID == workspaceID else { return }
        selectionLatency = nil
        signposts.end(pending.interval)
    }
}
