import CMUXAgentLaunch
import CmuxControlSocket
import CmuxFeedUI
import Foundation

/// The feed-domain (workstream) witnesses are the byte-faithful bodies of the
/// former `v2FeedJump` / `v2FeedList` dispatchers. Both ran on the main actor
/// already (they were not `nonisolated`), so there is no per-read `v2MainSync`
/// hop to shed; the work is the same `FeedCoordinator.shared` reads the legacy
/// bodies performed, with the per-item encoding (`FeedSocketEncoding.itemDict`)
/// bridged to `JSONValue` so the wire bytes match exactly.
///
/// Only the MAIN-ACTOR feed methods move here. The worker-lane feed methods
/// (`feed.push`, `feed.permission.reply`, `feed.question.reply`,
/// `feed.exit_plan.reply`) stay on the app-side socket-worker path.
extension TerminalController: ControlFeedContext {
    func controlFeedResolvePossibleSurface(workstreamID: String) -> Bool {
        FeedCoordinator.shared.socketRouter.resolvePossibleSurface(for: workstreamID)
    }

    func controlFeedSnapshotItems(pendingOnly: Bool) -> [JSONValue] {
        FeedCoordinator.shared.socketRouter.snapshot(pendingOnly: pendingOnly).map { item in
            // `WorkstreamItem.socketEncodedDictionary` only ever produces valid
            // JSON (strings, bools, arrays, nested dicts), so the bridge never
            // fails; the empty-object fallback exists solely to keep the map total.
            JSONValue(
                foundationObject: item.socketEncodedDictionary(
                    codexCapabilityToolInputJSON: FeedPermissionActionPolicy.codexCapabilityToolInputJSON
                )
            ) ?? .object([:])
        }
    }
}
