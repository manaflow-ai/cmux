import CmuxControlSocket
import Foundation

/// The feed-domain (workstream) witnesses are the byte-faithful bodies of the
/// former `v2FeedJump` / `v2FeedList` dispatchers. Both ran on the main actor
/// already (they were not `nonisolated`), so there is no per-read `v2MainSync`
/// hop to shed; the work is the same `FeedCoordinator.shared` reads the legacy
/// bodies performed, with the per-item encoding (`FeedSocketEncoding.itemDict`)
/// bridged to `JSONValue` so the wire bytes match exactly.
///
/// Feed jump exposes both async and synchronous resolution witnesses: the real
/// socket awaits the actor-owned lookup, while off-main in-process workers use
/// the direct compatibility reader. The blocking feed methods (`feed.push`,
/// `feed.permission.reply`, `feed.question.reply`, `feed.exit_plan.reply`)
/// stay on the app-side socket-worker path.
extension TerminalController: ControlFeedContext {
    nonisolated func controlFeedInvalidJumpMessage() -> String {
        String(
            localized: "socket.feed.jump.invalidParams",
            defaultValue: "feed.jump requires workstream_id"
        )
    }

    nonisolated func controlFeedResolvePossibleSurfaceAsync(
        workstreamID: String
    ) async -> Bool {
        await FeedCoordinator.shared.resolvePossibleSurfaceAsync(for: workstreamID)
    }

    nonisolated func controlFeedResolvePossibleSurface(
        workstreamID: String
    ) -> Bool {
        FeedJumpResolver.resolve(workstreamID) != nil
    }

    @MainActor
    func controlFeedSnapshotItems(pendingOnly: Bool) -> [JSONValue] {
        FeedCoordinator.shared.snapshot(pendingOnly: pendingOnly).map { item in
            // `FeedSocketEncoding.itemDict` only ever produces valid JSON
            // (strings, bools, arrays, nested dicts), so the bridge never fails;
            // the empty-object fallback exists solely to keep the map total.
            JSONValue(foundationObject: FeedSocketEncoding.itemDict(item)) ?? .object([:])
        }
    }
}
