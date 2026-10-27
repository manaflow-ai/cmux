#if os(iOS)
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "live")

/// A Mac's pairing code (``PairInvite``): the phone moves to the code's team,
/// focuses its Mac and pairs, and that Mac's `auth` presents the code's token.
extension LiveCoordinator {
    /// Takes a scanned or opened code. False when it expired, this phone has no
    /// pairing keys, or its team is not one of this account's spaces.
    @discardableResult
    public func accept(_ invite: PairInvite) -> Bool {
        guard let pairing, !invite.isExpired() else { return false }
        let personal = Self.personalTeamID(userID: userID)
        if !store.teams.isEmpty, invite.team != personal, !store.teams.contains(where: { $0.id == invite.team }) {
            log.info("pairing code for a space this account is not in")
            return false
        }
        // Before the spaces load it is held only; steerToInvite checks the space before it moves.
        // A code whose token was already presented is not taken again.
        guard pairing.invites.hold(invite) else { return false }
        log.info("pairing code for \(invite.mac, privacy: .private)")
        steerToInvite()
        return true
    }

    /// Moves to the held code's space, then to its Mac once that space's Macs
    /// are loaded (run again when the teams or Macs arrive).
    func steerToInvite() {
        guard let pairing, let invite = pairing.invites.pending() else { return }
        let personal = invite.team == Self.personalTeamID(userID: userID)
        // A code taken before this account's spaces loaded is checked again once they have:
        // one for a space this account is not in is dropped, and nothing moves for it.
        guard personal || store.teams.contains(where: { $0.id == invite.team }) else {
            if !store.teams.isEmpty {
                log.info("pairing code for a space this account is not in")
                pairing.invites.drop()
            }
            return
        }
        // Remembered per team, as a pick in the Macs list is: the team's Macs focus it when they load.
        let pick = "cmuxMobile.live.mac.\(invite.team)"
        if UserDefaults.standard.string(forKey: pick) != invite.mac { UserDefaults.standard.set(invite.mac, forKey: pick) }
        guard store.activeTeamID == invite.team else {
            if personal {
                selectPersonal()
            } else {
                store.selectTeam(invite.team)
                activeTeamChanged(byUser: true)
                onFollow?(invite.team)
            }
            return
        }
        guard registeredTeamID == invite.team, store.activeTeam?.macs.contains(where: { $0.id == invite.mac }) == true,
              canLink(macID: invite.mac) else { return }
        if focusedMacID != invite.mac { retarget() }
        // Another build on a listed computer (MacRoster lists one per computer) is not focused:
        // the held code pins it (MacLinkPolicy `pinned`), so it is dialed whatever else is shown.
        if focusedMacID != invite.mac { applyLinks() }
        guard let session = sessions[invite.mac] else { return }
        switch session.pairingState {
        case .paired:
            // Allowed already: nothing left to approve.
            pairing.invites.drop(mac: invite.mac)
        case .waiting, .waitingAfterNewKeys:
            // This link's `auth` answered its challenge without the code: a new link presents it.
            redial(session)
        case .denied, .failed:
            retry(macID: invite.mac)
        case .idle:
            // The link's challenge is still to come (it presents the code), or `onWaiting` redials.
            break
        }
    }

    /// Closes a Mac's link and dials it again (a new `auth`).
    func redial(_ session: MacSession) {
        guard let target = session.link.target else { return }
        session.link.send(.target(nil))
        session.link.send(.target(target))
    }
}
#endif
