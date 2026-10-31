public import CmuxNextCompat
public import Foundation
import os

/// The app's daemon update, one per app (`AppServices` makes it): the one queue every machine's
/// update goes through, one at a time (``policy``), the board it reports to, which the sidebar of
/// every window and Settings read (``board``), and the acpmux ssh peers that connect later in the
/// launch (``reconnects``), which the app's turn-state watch feeds (``peerSessionChanged(_:stale:)``).
@MainActor
public final class DaemonUpdates {
    public nonisolated let board: DaemonUpdateBoard
    public nonisolated let policy: DaemonUpdatePolicy
    let reconnects: AcpmuxPeerReconnects
    /// ``startOnce(build:environment:download:)`` ran.
    private var started = false

    /// The app's: the board keeps its closed notice in the policy's directory, the policy pushes
    /// the bundled acpmux's build and reports to the board, and the peers that connect later are
    /// offered to the policy while `agent.updatePeers` is on.
    public init() {
        let board = DaemonUpdateBoard(closedNoticeFile: DaemonUpdatePolicy.defaultDirectory.appendingPathComponent("notice-closed"))
        let policy = DaemonUpdatePolicy(DaemonUpdatePolicy.Dependencies(
            bundledBuild: { await DaemonUpdatePolicy.bundledAcpmuxBuild() },
            report: { event in await MainActor.run { board.apply(event) } }
        ))
        self.board = board
        self.policy = policy
        reconnects = AcpmuxPeerReconnects(offer: { await policy.offer($0) },
                                          enabled: { AgentPaneTunables.updatePeersAutomatically.value })
    }

    /// A session of acpmux peer `peer` changed on the app's own acpmux, `stale` when the peer
    /// dropped (`AgentTurnStateFeed`): a peer that connects later in the launch gets the app's
    /// build too (``AcpmuxPeerReconnects/note(peer:stale:)``). O(1) unless the peer was not known
    /// connected.
    public func peerSessionChanged(_ peer: String, stale: Bool) {
        _ = reconnects.note(peer: peer, stale: stale)
    }

    /// Once per launch, in the background, after the app's acpmux is up (``AcpmuxHost/prewarm()``):
    /// offers the acpmux ssh peers of the app's daemon to ``policy``, and arms ``reconnects`` and its
    /// sweep for the peers that connect later. `download` fetches a published artifact of the
    /// bundled build next to `executable` (the app wires `RemoteInstaller.download(artifact:nextTo:)`).
    public func startOnce(
        build: BuildIdentity?, environment: [String: String],
        download: @escaping @Sendable (_ artifact: String, _ executable: URL) async throws -> (file: URL, commit: String)
    ) {
        guard !started else { return }
        started = true
        guard AgentPaneTunables.updatePeersAutomatically.value else { return }
        guard DaemonUpdatePolicy.updatesPeers(build: build, environment: environment) else {
            DaemonUpdatePolicy.logger.info("daemon update skipped: attached to another app's acpmux")
            return
        }
        let (policy, reconnects) = (policy, reconnects)
        // task-owner: once per launch; ends when the peers are offered (the app's policy updates them)
        Task.detached(priority: .utility) {
            let bin = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
            guard let acpmux = AcpmuxEnvironment.resolve(build: build, bundledBinDirectory: bin, environment: environment) else {
                DaemonUpdatePolicy.logger.info("daemon update skipped: no acpmux")
                return
            }
            let peers = AcpmuxPeerUpdateSource.live(acpmux, directory: DaemonUpdatePolicy.defaultDirectory, download: download)
            await MainActor.run { reconnects.source = peers }
            for target in await peers.targets() {
                await policy.offer(target)
            }
            await MainActor.run { _ = reconnects.sweep(peers, every: .seconds(600), clock: ContinuousClock()) }
        }
    }
}
