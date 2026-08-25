import Foundation

/// Identifies workspace panels whose cached agent-index fingerprint changed.
///
/// The loader already computes fingerprints off the main actor. Keeping the
/// set-difference projection separate lets notification consumers refresh only
/// affected sidebar rows without reloading every workspace.
struct RestorableAgentSessionIndexChangeSet: Sendable, Equatable {
    let panelIdsByWorkspaceId: [UUID: Set<UUID>]

    init(previous: Set<String>, current: Set<String>) {
        var changed: [UUID: Set<UUID>] = [:]
        for fingerprint in previous.symmetricDifference(current) {
            let fields = fingerprint.split(separator: "|", maxSplits: 2)
            guard fields.count >= 2,
                  let workspaceId = UUID(String(fields[0])),
                  let panelId = UUID(String(fields[1])) else {
                continue
            }
            changed[workspaceId, default: []].insert(panelId)
        }
        panelIdsByWorkspaceId = changed
    }
}
