import Foundation

/// Offers an acpmux ssh peer to ``DaemonUpdatePolicy/shared`` when it connects later in the
/// launch. The launch's discovery (``DaemonUpdatePolicy/startOnce(build:environment:download:)``)
/// sees only the peers connected within its settling window, and a peer the policy dropped while
/// it was off the network is not asked again by itself: without this, a teammate's machine that
/// comes online an hour later keeps its old daemon until the next launch.
///
/// No new stream and no polling: the app's own `_acpmux/watch` (`AgentTurnStateFeed`) already
/// carries every change of a peer's sessions with the peer's name, and those change when the peer
/// connects (its fresh list replaces the cached rows) and when it drops (they turn `stale`). The
/// first live change of a peer not known connected reads the local daemon's status once
/// (``AcpmuxPeerUpdateSource/check(peer:)``) and offers the peer when it is a connected ssh peer
/// that named its build; the policy and its ledger keep that to one update per build. What those
/// changes cannot show, ``sweep(_:every:clock:)`` catches within ten minutes.
@MainActor
public final class AcpmuxPeerReconnects {
    // lint:allow one per app process: the app's turn-state watch feeds it, the launch's discovery arms it
    public static let shared = AcpmuxPeerReconnects.app()

    /// The app's: offers go to ``DaemonUpdatePolicy/shared``, `enabled` reads `agent.updatePeers`.
    /// Built in a function, not the property's initializer, so its closures are not checked as part
    /// of that initializer's isolation (Swift 6 refuses one that mixes the main actor and another).
    private static func app() -> AcpmuxPeerReconnects {
        AcpmuxPeerReconnects(offer: { await DaemonUpdatePolicy.shared.offer($0) },
                             enabled: { AgentPaneTunables.updatePeersAutomatically.value })
    }

    /// The acpmux side, set by the launch's discovery; nil before, when every note is ignored.
    var source: AcpmuxPeerUpdateSource?
    private let offer: @Sendable (any DaemonUpdateTarget) async -> Void
    private let enabled: @Sendable () -> Bool
    /// Peers whose last change was live, checked once since: their next changes read nothing.
    private var live: Set<String> = []

    /// `enabled`: `agent.updatePeers`, read before each status read.
    init(offer: @escaping @Sendable (any DaemonUpdateTarget) async -> Void, enabled: @escaping @Sendable () -> Bool) {
        self.offer = offer
        self.enabled = enabled
    }

    /// One change of a session of acpmux peer `peer` on the app's acpmux; `stale` when the peer
    /// dropped. O(1) unless the peer was not known connected; then one status read in the
    /// background, returned so tests can await it.
    @discardableResult
    public func note(peer: String, stale: Bool) -> Task<Void, Never>? {
        guard !stale else {
            live.remove(peer)
            return nil
        }
        guard let source, !live.contains(peer), enabled() else { return nil }
        live.insert(peer)
        let offer = offer
        // task-owner: one status read per connect of a peer, off the main actor; ends once the peer is offered or found not up
        return Task.detached(priority: .utility) { [weak self] in
            switch await source.check(peer: peer) {
            case .target(let target): await offer(target)
            // Not up after all (it dropped again, or has not named its build yet): its next change checks again.
            case .notConnected: await self?.forget(peer)
            case .skipped: break
            }
        }
    }

    /// Offers every connected ssh peer again every `interval` while `agent.updatePeers` is on, and
    /// ends when it is turned off (the next launch starts it again). It catches what
    /// ``note(peer:stale:)`` cannot see: a peer that connects with no session sends no change, a
    /// reconnect of the app's watch brings a snapshot and no changes, and an offer that came while
    /// the policy still ran that peer's earlier attempt is dropped. One local status read per
    /// `interval`; the policy and its ledger keep it to one update per build.
    @discardableResult
    func sweep(_ source: AcpmuxPeerUpdateSource, every interval: Duration, clock: any Clock<Duration>) -> Task<Void, Never> {
        let offer = offer
        let enabled = enabled
        // task-owner: one per launch (startOnce); ends when agent.updatePeers is turned off or the task is cancelled
        return Task.detached(priority: .utility) {
            // wakeup-allow: one local status read every ten minutes while peer updates are on
            while (try? await clock.sleep(for: interval)) != nil, enabled() {
                for target in await source.targetsNow() {
                    await offer(target)
                }
            }
        }
    }

    private func forget(_ peer: String) {
        live.remove(peer)
    }
}

nonisolated extension AcpmuxPeerUpdateSource {
    /// What ``check(peer:)`` found.
    enum PeerCheck {
        /// A connected ssh peer that named its build, and the local daemon may push to it.
        case target(AcpmuxPeerUpdateTarget)
        /// Not connected, or connected but without a build yet; or the local daemon did not answer.
        case notConnected
        /// Never a target while this daemon runs: not an ssh peer, an unknown name, or the local
        /// daemon may not push its build (``AcpmuxPeerUpdateStatus/blocked(bundledBuild:)``).
        case skipped
    }

    /// Peer `name` as the local daemon's status shows it now, without the launch's settling wait.
    func check(peer name: String) async -> PeerCheck {
        guard let status = await status() else { return .notConnected }
        guard let peer = status.peers.first(where: { $0.name == name }) else { return .skipped }
        guard peer.connected, peer.remoteBuild != nil else { return .notConnected }
        if let blocked = status.blocked(bundledBuild: await bundledBuild()) {
            Self.logger.info("acpmux peer \(name, privacy: .public) skipped: \(blocked, privacy: .public)")
            return .skipped
        }
        guard status.updatablePeers.contains(peer) else { return .skipped }
        return .target(AcpmuxPeerUpdateTarget(name: peer.name, url: peer.url, source: self))
    }
}
