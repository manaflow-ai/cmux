import Foundation

/// Stateless-per-call decision core for the guardrail. Owns only the
/// warned/dismissed sets so the threshold crossing logic (edge-trigger +
/// hysteresis) is testable without timers, ghostty, or libproc.
struct PaneMemoryGuardrailEngine {
    /// Banner clears once a warned pane drops below `clearFraction × threshold`.
    /// The gap between warn and clear is hysteresis so a pane hovering at the
    /// threshold does not flap the badge/banner every tick.
    static let clearFraction = 0.8

    private(set) var warnedPanes: Set<PaneMemoryPaneKey> = []
    private(set) var dismissedPanes: Set<PaneMemoryPaneKey> = []

    var warnedWorkspaceIds: Set<UUID> { Set(warnedPanes.map(\.workspaceId)) }

    mutating func ingest(samples: [PaneMemorySample], thresholdBytes: Int64) -> PaneMemoryGuardrailEngineOutput {
        let clearBytes = Int64(Double(thresholdBytes) * Self.clearFraction)
        let liveKeys = Set(samples.map(\.key))
        // Forget panes that no longer exist so closed panes never keep a badge.
        warnedPanes.formIntersection(liveKeys)
        dismissedPanes.formIntersection(liveKeys)

        var bannersToPresent: [PaneMemoryWarning] = []
        var clearedPanes: Set<PaneMemoryPaneKey> = []

        for sample in samples {
            let key = sample.key
            if sample.memoryBytes >= thresholdBytes {
                if warnedPanes.insert(key).inserted, !dismissedPanes.contains(key) {
                    // First crossing (or first since it cleared) — fire once.
                    bannersToPresent.append(sample.warning)
                }
            } else if sample.memoryBytes < clearBytes {
                warnedPanes.remove(key)
                dismissedPanes.remove(key)
                clearedPanes.insert(key)
            }
            // In the hysteresis band [clearBytes, thresholdBytes): keep state.
        }

        return PaneMemoryGuardrailEngineOutput(
            bannersToPresent: bannersToPresent,
            warnedWorkspaceIds: warnedWorkspaceIds,
            warnedPaneKeys: warnedPanes,
            clearedPanes: clearedPanes
        )
    }

    /// User dismissed the banner for `key`; suppress re-firing while it stays
    /// high. The badge persists until the pane drops below the clear level.
    mutating func dismiss(_ key: PaneMemoryPaneKey) {
        dismissedPanes.insert(key)
    }

    /// The pane's runaway tree was killed; drop its warned/dismissed state so a
    /// future leak re-warns cleanly.
    mutating func acknowledgeHandled(_ key: PaneMemoryPaneKey) {
        warnedPanes.remove(key)
        dismissedPanes.remove(key)
    }

    mutating func reset() {
        warnedPanes.removeAll()
        dismissedPanes.removeAll()
    }
}
