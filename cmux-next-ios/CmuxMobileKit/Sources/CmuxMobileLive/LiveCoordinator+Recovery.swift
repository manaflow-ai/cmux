#if os(iOS)
import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "live")

/// Retry from a Mac's own view, in steps the person can watch (cmux#52200). Leo, 2026-11-23:
/// "Cosmic Gray appears offline on my iOS phone. I cannot access or revive the computer from
/// iOS. I need that to be recoverable."
///
/// 1. Reaching the cmux service: ask it for the Mac's presence now (`GET /v1/me/macs`), not at
///    the next poll, so a Mac that came back shows it, and one that is quiet says how long.
/// 2. Reaching the Mac: dial it whatever presence says (a stale "offline" is never final
///    without a dial behind it), as a surface of the Mac opening does.
/// 3. Opening your sessions: the link is up; the Mac's daemon sends its workspaces.
///
/// Nothing here closes a session: the dial reuses the Mac's link machinery, whose redial keeps
/// every tab, chat and terminal on the Mac and reattaches them when the link is back.
extension LiveCoordinator {
    /// How long one Retry waits for the Mac before it says how far it got: the dial's own
    /// timeout (25 s) and one silent redial fit.
    static let recoveryDeadline: Duration = .seconds(40)

    public func recover(macID: String) {
        guard store.macRecovery[macID]?.isRunning != true else { return }
        store.macRecovery[macID] = MacRecoveryAttempt(step: .service)
        let clock = clock
        Task { [weak self] in
            guard let self else { return }
            // Step 1: the service. A phone with no network stops here.
            let listed: [LiveAPI.Mac]
            do {
                listed = try await self.api.myMacs()
            } catch {
                log.error("recover \(macID, privacy: .public): service: \(String(describing: error), privacy: .public)")
                self.finishRecovery(macID, MacRecoveryAttempt(step: .service, result: .failed(.service)))
                return
            }
            if let mac = listed.first(where: { $0.deviceId == macID }),
               self.store.activeTeam?.macs.contains(where: { $0.id == macID }) == true {
                self.applyPresence(mac)
            }
            // Step 2: the Mac. A failure from before this try is not this try's answer.
            self.store.macRecovery[macID] = MacRecoveryAttempt(step: .mac)
            self.store.macFailure[macID] = nil
            if let session = self.sessions[macID], session.link.phase.isConnected {
                self.retry(macID: macID)
            } else {
                self.openSurface(macID: macID)
            }
            let started = self.instants.now()
            var sawDial = false
            while let attempt = self.store.macRecovery[macID], attempt.isRunning {
                if started.duration(to: self.instants.now()) >= Self.recoveryDeadline {
                    self.finishRecovery(macID, attempt.timedOut())
                    return
                }
                let seen = self.recoveryObservation(macID)
                if seen == .dialing || seen == .linked { sawDial = true }
                // Just after the dial is sent the phase may still read offline: give it a beat.
                if seen == .offline, !sawDial, started.duration(to: self.instants.now()) < .seconds(2) {
                    do { try await clock.sleep(for: .milliseconds(250)) } catch { return }
                    continue
                }
                let next = attempt.advanced(by: seen)
                if !next.isRunning {
                    self.finishRecovery(macID, next)
                    return
                }
                if next != attempt { self.store.macRecovery[macID] = next }
                do { try await clock.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }

    /// Records the end of a Retry: what it learned about the Mac stays on its view.
    private func finishRecovery(_ macID: String, _ attempt: MacRecoveryAttempt) {
        store.macRecovery[macID] = attempt
        switch attempt.result {
        case .connected?:
            store.macFailure[macID] = nil
        case .failed(.mac)?:
            // The dial reached no Mac: say so, not a bare "offline".
            if store.macFailure[macID] == nil { store.macFailure[macID] = .hostUnreachable }
        case .failed(.session)?:
            if store.macFailure[macID] == nil { store.macFailure[macID] = .serviceDown }
        case .failed(.service)?, nil:
            break
        }
        log.info("recover \(macID, privacy: .public): \(String(describing: attempt.result), privacy: .public) at \(String(describing: attempt.step), privacy: .public)")
    }

    /// What the Mac's link shows now, for ``MacRecoveryAttempt/advanced(by:)``.
    private func recoveryObservation(_ macID: String) -> MacRecoveryAttempt.Observation {
        if store.macConnection[macID] == .connected, store.macData[macID]?.source == .live { return .live }
        if let failure = store.macFailure[macID] { return .failed(failure) }
        switch sessions[macID]?.link.phase {
        case .connected?: return .linked
        case .macOffline?: return .offline
        case .signedOut?: return .failed(.authRequired)
        case .waiting?: return .failed(.hostUnreachable)
        case .connecting?, .idle?, nil: return .dialing
        }
    }

    /// The Mac as the service just listed it, applied as a presence frame would be.
    private func applyPresence(_ mac: LiveAPI.Mac) {
        guard let teamID = store.activeTeamID.isEmpty ? nil : store.activeTeamID else { return }
        var current = store.teams.first { $0.id == teamID }?.macs ?? []
        guard let index = current.firstIndex(where: { $0.id == mac.deviceId }) else { return }
        let known = current[index]
        current[index] = MacDevice(id: mac.deviceId, name: mac.name, isOnline: mac.online,
                                   lastSeenAt: mac.lastSeenDate ?? known.lastSeenAt, ownerUserID: known.ownerUserID,
                                   machineID: mac.machineId ?? known.machineID, quietMs: mac.quietMs)
        if current[index] != known { store.setMacs(current, teamID: teamID) }
    }

    /// Why a dial failed, from the link's display reason (``LinkController/reason(_:)``).
    nonisolated static func failure(waitingReason reason: String) -> MacLinkFailure {
        switch reason {
        case LinkController.reason(LinkError(code: "not_admitted", message: "")): .notAllowed
        case LinkController.reason(LinkError(code: LinkError.unauthorized, message: "")): .authRequired
        default: .hostUnreachable
        }
    }
}
#endif
