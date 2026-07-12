import CmuxControlSocket
import Foundation

/// The feed-domain (workstream) witnesses are the byte-faithful bodies of the
/// former `v2FeedList` dispatcher. It ran on the main actor already (it was not
/// `nonisolated`), so there is no per-read `v2MainSync` hop to shed; the work is
/// the same `FeedCoordinator.shared` read the legacy body performed, with the
/// per-item encoding (`FeedSocketEncoding.itemDict`) bridged to `JSONValue` so
/// the wire bytes match exactly.
///
/// Only the MAIN-ACTOR feed methods move here. The worker-lane feed methods
/// (`feed.push`, `feed.permission.reply`, `feed.question.reply`,
/// `feed.exit_plan.reply`, `feed.jump`) stay on the app-side socket-worker path.
extension TerminalController: ControlFeedContext {
    func controlFeedSnapshotItems(pendingOnly: Bool) -> [JSONValue] {
        FeedCoordinator.shared.snapshot(pendingOnly: pendingOnly).map { item in
            // `FeedSocketEncoding.itemDict` only ever produces valid JSON
            // (strings, bools, arrays, nested dicts), so the bridge never fails;
            // the empty-object fallback exists solely to keep the map total.
            JSONValue(foundationObject: FeedSocketEncoding.itemDict(item)) ?? .object([:])
        }
    }
}
