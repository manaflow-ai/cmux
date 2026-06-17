import Foundation

/// A single browser pane's live media activity, as reported to the
/// ``BrowserMediaActivityCenter``.
///
/// `isPlayingAudio` means the pane is producing *audible* output (an unmuted,
/// non-zero-volume `<video>`/`<audio>` element is playing and the pane is not
/// page-muted) — not merely that some muted autoplay video is rolling. Camera /
/// microphone reflect `WKMediaCaptureState != .none` (the device is engaged),
/// matching the macOS privacy-indicator convention.
struct PaneMediaActivity: Equatable, Sendable {
    var isPlayingAudio: Bool
    var isUsingMicrophone: Bool
    var isUsingCamera: Bool

    static let none = PaneMediaActivity(
        isPlayingAudio: false,
        isUsingMicrophone: false,
        isUsingCamera: false
    )

    var isActive: Bool { isPlayingAudio || isUsingMicrophone || isUsingCamera }
}

/// Aggregated media activity across every browser pane in one workspace. The
/// sidebar workspace row renders an indicator glyph from this.
struct WorkspaceMediaActivity: Equatable, Sendable {
    var isPlayingAudio: Bool
    var isUsingMicrophone: Bool
    var isUsingCamera: Bool

    static let none = WorkspaceMediaActivity(
        isPlayingAudio: false,
        isUsingMicrophone: false,
        isUsingCamera: false
    )

    var isActive: Bool { isPlayingAudio || isUsingMicrophone || isUsingCamera }
}

/// One pane's contribution to the per-workspace aggregate.
struct BrowserMediaActivityEntry: Equatable, Sendable {
    let workspaceId: UUID
    let activity: PaneMediaActivity
}

/// Collects per-pane media activity (audio / mic / camera) reported by each
/// ``BrowserPanel`` and folds it into a per-workspace aggregate the sidebar can
/// render (issue #6100).
///
/// Mirrors the ``PaneMemoryGuardrail`` → ``SidebarUnreadModel`` data flow: panes
/// push live state into the shared center, the center coalesces (only re-emits
/// on a real change), and `AppDelegate` wires ``onActivityChanged`` to mirror
/// the result into `SidebarUnreadModel` so the workspace list re-renders through
/// the same snapshot-boundary-safe observation path as unread / memory state.
@MainActor
final class BrowserMediaActivityCenter {
    static let shared = BrowserMediaActivityCenter()

    /// Invoked with the latest per-workspace aggregate whenever it changes.
    var onActivityChanged: (([UUID: WorkspaceMediaActivity]) -> Void)?

    private var entriesByPanelId: [UUID: BrowserMediaActivityEntry] = [:]
    private var workspaceAggregate: [UUID: WorkspaceMediaActivity] = [:]

    /// `internal` (not `private`) so unit tests can construct an isolated
    /// instance instead of mutating the shared singleton.
    init() {}

    /// Records (or clears) a pane's media activity. A pane with no active media
    /// is removed so it stops contributing to its workspace's aggregate.
    func update(panelId: UUID, workspaceId: UUID, activity: PaneMediaActivity) {
        if activity.isActive {
            let entry = BrowserMediaActivityEntry(workspaceId: workspaceId, activity: activity)
            if entriesByPanelId[panelId] == entry { return }
            entriesByPanelId[panelId] = entry
        } else {
            if entriesByPanelId[panelId] == nil { return }
            entriesByPanelId.removeValue(forKey: panelId)
        }
        recomputeAndNotify()
    }

    /// Drops a pane entirely (panel closed / deallocated).
    func remove(panelId: UUID) {
        guard entriesByPanelId.removeValue(forKey: panelId) != nil else { return }
        recomputeAndNotify()
    }

    /// Re-emits the current aggregate. Used right after wiring
    /// ``onActivityChanged`` so a late subscriber receives existing state.
    func flush() {
        onActivityChanged?(workspaceAggregate)
    }

    /// Current aggregate snapshot (test/inspection seam).
    var currentWorkspaceActivity: [UUID: WorkspaceMediaActivity] {
        workspaceAggregate
    }

    private func recomputeAndNotify() {
        let aggregate = Self.aggregate(entriesByPanelId)
        guard aggregate != workspaceAggregate else { return }
        workspaceAggregate = aggregate
        onActivityChanged?(aggregate)
    }

    /// Pure fold of per-pane entries into a per-workspace aggregate. Exposed for
    /// unit testing.
    static func aggregate(
        _ entries: [UUID: BrowserMediaActivityEntry]
    ) -> [UUID: WorkspaceMediaActivity] {
        var aggregate: [UUID: WorkspaceMediaActivity] = [:]
        for entry in entries.values {
            var current = aggregate[entry.workspaceId] ?? .none
            current.isPlayingAudio = current.isPlayingAudio || entry.activity.isPlayingAudio
            current.isUsingMicrophone = current.isUsingMicrophone || entry.activity.isUsingMicrophone
            current.isUsingCamera = current.isUsingCamera || entry.activity.isUsingCamera
            aggregate[entry.workspaceId] = current
        }
        return aggregate
    }
}
