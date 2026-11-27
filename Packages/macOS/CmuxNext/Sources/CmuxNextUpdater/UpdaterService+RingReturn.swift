public import CmuxUpdater
public import Foundation

/// The way back from a faster ring (``RingReturn``): read on demand when the Channels card
/// shows a ring, and taken by the card's Go Back button through the one drop-back path
/// (``UpdateDropBack``), which refuses a kept build that cannot read the stores.
extension UpdaterService {
    /// What following `ring` does to the running build. Offline, or with the feed unreadable,
    /// it says nothing (``RingReturn/none``); a kept build a rollback would refuse waits.
    public func ringReturn(to ring: UpdateRing) async -> RingReturn {
        // Sparkle's allowedChannels reads the baked feed, not a test feed: the same as ``probe()``.
        let allowed = identity.feed().channel.allowedSparkleChannels(ring: ring)
        var feedIdentity = identity
        if let testFeedURL { feedIdentity.infoFeedURL = testFeedURL }
        guard let offered = try? await prober.offered(feedIdentity, allowedChannels: allowed) else { return .none }
        let kept = await Task.detached { [keptVersions] in keptVersions.list() }.value
        let folder = changelogNotes.map { Self.channelFolder(notesBase: $0.notesBase) }
        var promoted: Set<String> = []
        if ring == .nightly {
            let verdicts = await Self.verdicts(for: kept.map(\.build) + [identity.build], in: folder)
            promoted = Set(verdicts.filter { $0.value == "pass" }.keys)
        }
        // A pulled build keeps its canary pass: the pulled list rules it out as a way back.
        let pulled = Set(await Self.pulled(in: folder).map(\.build))
        let decision = RingReturn.decide(installedBuild: identity.build, offered: offered, promoted: promoted,
                                         pulled: pulled, kept: kept)
        guard case .goBack(let target) = decision else { return decision }
        let runs = (try? await UpdateDropBack(self).run(to: target.build, checkOnly: true,
                                                        stateDirectories: pulledWatch.stateDirectories())) != nil
        return runs ? decision : .waits
    }

    /// The card's Go Back: restarts into `build` when `ring` is the followed ring and
    /// ``ringReturn(to:)`` still offers it. Nil when it runs, else what the person reads.
    public func returnToRing(_ ring: UpdateRing, build: String) async -> String? {
        guard ring == self.ring, case .goBack(let target) = await ringReturn(to: ring), target.build == build else {
            return UpdaterStrings.channelsGoBackGone
        }
        log.append("ring \(ring.rawValue): going back to kept build \(build)")
        return await UpdateDropBack(self).failure(to: build, stateDirectories: pulledWatch.stateDirectories())
    }
}
