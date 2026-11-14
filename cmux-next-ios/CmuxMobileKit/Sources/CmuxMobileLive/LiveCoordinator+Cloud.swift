#if os(iOS)
import CmuxMobileChief
import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "cloud")

/// Why a Cloud machine's carrier refused this phone, as its line says it.
struct CloudRefusal: Equatable, Sendable {
    var code: String
    var note: String
    /// The machine as the list showed it when the carrier refused (a change lifts some refusals).
    var listed: MacDevice?
    var at: ContinuousClock.Instant = .now
}

/// Cloud machines as machines (plans/cmux-next/cloud-ios.md §3.1, "every machine is a
/// daemon"): each running one is one more session, keyed by its `vm_…` id, whose link is its
/// carrier. Its workspaces, terminals (the whole sizing protocol), rename, close and creation
/// then run through the same `WorkspaceSync`, `DaemonTerminalSession` and creation backend as
/// a Mac's. Nothing a Cloud machine does not serve on its carrier is opened (pairing,
/// `version`, acpmux, the Mac Feed, push, Chief). Cloud machines never join a team's Macs.
extension LiveCoordinator {
    /// Whether `macID` is one of the account's Cloud machines.
    public func isCloud(macID: String) -> Bool {
        sessions[macID]?.isCloud ?? store.isCloudMachine(macID)
    }

    /// The running Cloud machines this phone may dial now (not refused, Cloud dialer present).
    var dialableCloudMachines: [MacDevice] {
        guard cloudDialer != nil else { return [] }
        return store.cloudMachines.filter { $0.isOnline && cloudRefusals[$0.id] == nil && cloudDropHolds[$0.id] == nil }
    }

    /// The account's Cloud machines (`cloud.machine.list`, as `LiveCloudWorkspaces` reads it):
    /// listed beside the Macs, the running ones dialed lazily like Macs. A machine that left
    /// the list (deleted) closes its link and its rows go; one that stopped running closes
    /// its link and keeps its rows as last known.
    /// `fromRead`: the machines come from a list read that succeeded just now (not a republish of
    /// the last one, not a failed or cancelled read): a machine whose carrier dropped may be dialed
    /// again once such a read still says it runs. `readStamp` (``cloudReadStamp`` when the read
    /// began) limits that to the holds placed before the read; nil lifts every hold.
    /// `quiet`: the list empties because Cloud stops here (sign-out), not because machines left:
    /// no "was deleted" for the pages still open.
    public func applyCloudMachines(_ machines: [MacDevice], fromRead: Bool = false, readStamp: Int? = nil, quiet: Bool = false) {
        let machines = machines.filter(\.isCloud)
        // A set: a machine can hold both kinds (stale from a background, drop from a failed probe on
        // the way back); one read lifting both signals it once, never a second, cancelling dial.
        var lifted: Set<String> = []
        if fromRead {
            let stamp = readStamp ?? Int.max
            let now = cloudNow()
            // A quick-drop wait still running keeps its hold through the read.
            let keptDrops = cloudDropHolds.filter { $0.value > stamp || (cloudHoldNotBefore[$0.key].map { $0 > now } ?? false) }
            lifted = Set(cloudDropHolds.keys.filter { keptDrops[$0] == nil })
            cloudDropHolds = keptDrops
            cloudHoldNotBefore = cloudHoldNotBefore.filter { cloudDropHolds[$0.key] != nil }
            lifted.formUnion(cloudStaleHolds.filter { $0.value <= stamp }.keys)
            cloudStaleHolds = cloudStaleHolds.filter { $0.value > stamp }
        }
        // A held machine still targeted when this read lifts its hold skipped its dial and waits in
        // `connecting` (a stale hold; or a drop hold whose deferred un-target has not run yet, when
        // the read answers first): the read says it may dial, so it dials now. Taken before this
        // apply targets anything, so a machine this apply targets first dials once, never twice.
        let skippedDials = lifted.filter { id in
            guard let session = sessions[id] else { return false }
            return session.link.target != nil && !session.link.phase.isConnected
        }
        defer {
            for id in skippedDials {
                guard let session = sessions[id], session.link.target != nil, !session.link.phase.isConnected,
                      !cloudDialHeld(id) else { continue }
                session.link.send(.macSignaled)
            }
        }
        let before = Set(listedCloudMachines.map(\.id))
        let namesBefore = Dictionary(listedCloudMachines.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        listedCloudMachines = machines
        // A refusal that the list has since changed (paused, gone, started again) no longer holds.
        for (id, refusal) in cloudRefusals {
            guard let machine = machines.first(where: { $0.id == id }) else {
                cloudRefusals[id] = nil
                continue
            }
            if refusal.lifted(by: machine, now: .now) {
                cloudRefusals[id] = nil
                // Lifted on a list that is not a fresh read (a republish, an action's change): it
                // still waits for one begun after now before it dials (review round 20).
                if !fromRead { holdCloudDial(id) }
            }
        }
        publishCloudMachines()
        let ids = Set(machines.map(\.id))
        for gone in before.subtracting(ids) {
            // A page of it on screen ends with a word, not a silent jump back (criterion 7).
            if !quiet { onCloudMachineGone?(gone, namesBefore[gone] ?? "This Cloud machine") }
            // Its open pages close, as a removed Mac's do (a workspace on Workspaces or Settings).
            onMacRemoved?(gone)
            // Gone from the list (deleted): no later session takes its terminals.
            closeSession(gone, keepsTerminals: false)
            store.replaceWorkspaces(macID: gone, with: [])
            store.macData[gone] = nil
            lastShown[gone] = nil
        }
        // A machine that stopped running (paused, pausing, failed) keeps its session, as a Mac that
        // went offline does: its link closes (the cap leaves it out, as it is not online), its open
        // terminals say it is offline instead of "Reattaching…" for ever, and once it runs again
        // they reattach on the same session. Only a machine that left the list forgets it.
        for machine in machines {
            guard let session = sessions[machine.id] else { continue }
            if machine.isOnline {
                // Running (again): what its terminals say follows its link, as for any Mac, so a
                // stop that was called off (one read said pausing) never leaves them offline.
                if session.terminalsOffline { updateTerminalsOffline(session) }
                continue
            }
            session.terminalsOffline = true
            session.terminals.removeAll { $0.session == nil }
            for terminal in session.terminals { terminal.session?.setMacOffline(true) }
        }
        applyLinks()
    }

    /// The list's machines with this phone's refusals shown on them: a running machine whose
    /// carrier refused this phone reads as failed, with why, and offers Retry.
    func publishCloudMachines() {
        let shown = listedCloudMachines.map { machine -> MacDevice in
            guard let refusal = cloudRefusals[machine.id], var state = machine.cloud else { return machine }
            state.status = .failed
            state.note = refusal.note
            var refused = machine
            refused.cloud = state
            refused.isOnline = false
            return refused
        }
        if store.cloudMachines != shown { store.cloudMachines = shown }
    }

    /// A Cloud machine's carrier refused this phone for good: no more dials until Retry or
    /// the machine list changes; its line says why.
    func cloudRefused(_ machineID: String, _ error: LinkError) {
        let listed = listedCloudMachines.first { $0.id == machineID }
        let name = listed?.name ?? "this Cloud machine"
        log.error("cloud carrier refused: \(error.code, privacy: .public)")
        cloudRefusals[machineID] = CloudRefusal(code: error.code, note: CloudRefusal.note(error.code, machine: name), listed: listed)
        // A refusal that later lifts (the listing changed, a wait passed) lifts on what the phone
        // already had, maybe not a fresh read: the machine is also held until a read begun after
        // now says it runs, so a lifted refusal never dials on an older list.
        holdCloudDial(machineID)
        publishCloudMachines()
        applyLinks()
        onCloudRefusal?(machineID, error.code)
    }

    /// The person looked at a Cloud machine whose line is not running (unfolded it): its state may
    /// have moved since the last read (started elsewhere), so read the list now, not at the next
    /// idle poll (live capture at e8a158c3: a machine started elsewhere stayed "Paused" for 18 s).
    public func lookedAtCloudMachine(_ machineID: String) {
        guard isCloud(macID: machineID) else { return }
        onCloudHoldsWaiting?(false)
    }

    /// Whether the carrier refused this machine (Retry clears it).
    public func isCloudRefused(_ machineID: String) -> Bool { cloudRefusals[machineID] != nil }

    /// Retry on a machine its carrier refused (or whose session was signed out): a new session
    /// and link dial it now. The old one may be in `signedOut`, which never dials again.
    public func retryCloud(_ machineID: String) {
        cloudRefusals[machineID] = nil
        // The person asked: no quick-drop or failed-dial wait from before.
        cloudHoldNotBefore[machineID] = nil
        cloudQuickDrops[machineID] = nil
        cloudDialFailures[machineID] = nil
        closeSession(machineID)
        // Retry is the person's own ask to dial now: the close above holds nothing for it (any
        // hold from before goes too), as opening a machine needs no read to dial.
        cloudDropHolds[machineID] = nil
        cloudStaleHolds[machineID] = nil
        publishCloudMachines()
        touch(machineID)
    }

    /// A Cloud session's link was signed out (the service refused even a fresh token): its line
    /// says to sign in, and Retry starts over with a new session.
    func cloudSignedOut(_ session: MacSession) {
        guard session.isCloud, session.link.phase == .signedOut, cloudRefusals[session.macID] == nil else { return }
        cloudRefused(session.macID, LinkError(code: LinkError.unauthorized, message: "the service refused a fresh token"))
    }

    /// The most Cloud machines linked at once, beside the Macs' own `linkPolicy` cap: a Cloud
    /// machine never takes a Mac's link, and the one the person opened last is linked first.
    static let cloudLinkCap = 3

    /// Closes `session`'s link. A Cloud machine's terminals release their sizes first (all at
    /// once, answered, about 2 s at most), so the machine never keeps this phone's grid after the
    /// carrier goes. One close at a time per session: a second ask while one is releasing does
    /// nothing. The close goes out only if the session is still meant closed then: a link opened
    /// again meanwhile (`touch`, Retry, Connect: `cancelPendingClose`) stays up, and its terminals
    /// claim their sizes again.
    func closeLink(_ session: MacSession) {
        // The phone closes it (once per close, not per apply while it releases): the machine may
        // idle-pause unseen, so a new dial waits for a list read begun after now. A refused
        // machine dials again only on Retry (the person's own ask), so its close holds nothing.
        guard session.isCloud, session.link.phase.isConnected, session.link.target != nil else {
            if session.isCloud, session.link.target != nil, cloudRefusals[session.macID] == nil {
                holdCloudListStale([session.macID])
            }
            session.pendingClose = nil
            return session.link.send(.target(nil))
        }
        guard session.pendingClose == nil else { return }
        holdCloudListStale([session.macID])
        session.closeSerial &+= 1
        let token = session.closeSerial
        session.pendingClose = token
        let release = releaseBeforeClose
        // A close after a touch called an earlier one off waits for that one's releases, so the
        // link never closes while an earlier release is unanswered.
        let prior = session.releasing
        // task-owner: bounded by the releases' 2 s deadline (run together), after the prior ones
        let releases = Task { @MainActor in
            await prior?.value
            await release(session)
        }
        session.releasing = releases
        // task-owner: waits for `releases`, then the close
        // Strong: a session closeSession already forgot must still close its link.
        Task { @MainActor in
            await releases.value
            if session.releasing == releases { session.releasing = nil }
            guard session.pendingClose == token else {
                // Called off by a touch: what is on screen claims its size again while the link is still
                // wanted and no later close is pending, up or between a probe and a redial (a link that
                // comes back without a reattach must not leave a shown terminal claiming nothing).
                if session.pendingClose == nil, session.link.target != nil {
                    for terminal in session.terminals.compactMap(\.session) { terminal.reclaimSizeAfterKeptLink() }
                }
                return
            }
            session.pendingClose = nil
            session.link.send(.target(nil))
        }
    }

    /// A close waiting on its releases is called off: the link is wanted again.
    func cancelPendingClose(_ session: MacSession) {
        session.pendingClose = nil
    }

    /// Every terminal of `session` releases its size, together, before its link closes.
    static func releaseTerminals(_ session: MacSession) async {
        // Started together, so the whole release takes one 2 s bound, not one per terminal.
        let attaches = session.attachesAtClose
        let releases = session.terminals.compactMap(\.session).compactMap { terminal -> Task<Void, Never>? in
            guard let attaches else {
                return Task { @MainActor in await terminal.releaseBeforeLinkCloses() }
            }
            // A forgotten session: only a terminal still on the attach it had then (not detached
            // then, and not attached again since by the session that adopted it).
            guard case .some(.some(let attach)) = attaches[ObjectIdentifier(terminal)] else { return nil }
            // `attach` is the serial the terminal was on at the close (``DaemonTerminalSession/attachIdentity``).
            return Task { @MainActor in await terminal.releaseBeforeLinkCloses(onlyThrough: attach) }
        }
        for release in releases { await release.value }
    }

    /// A Cloud machine's daemon is serving its workspaces on this phone now.
    public func cloudDaemonReady(_ machineID: String) -> Bool {
        guard let session = sessions[machineID] else { return false }
        return session.creation.canCreate(on: machineID)
    }

    /// The account's Cloud carrier dialer for this build: nil when it has no Cloud service.
    /// `signedOut` says whether a token error means there is no sign-in (the app's auth layer's own
    /// error type); such an error, or a refused token (401), is `unauthorized` to the carrier, which
    /// then stops asking at once instead of retrying a transport failure until its deadline.
    public static func standardCloudDialer(userID: String, deviceName: String, api: LiveAPI,
                                           signedOut: @escaping @Sendable (any Error) -> Bool = { _ in false },
                                           secrets: any DeviceSecretStore = KeychainSecretStore()) -> (any MacLinkDialer)? {
        guard let config = ChiefCloudConfig.current() else { return nil }
        // Account-default scope, as the machine list reads it (no `x-cmux-team`): the phone's
        // active team is a Mac team (`personal-…` or a Stack id), not a Cloud `team_…` id.
        // This sign-in's epoch: a dial still running after sign-out can't write a key back.
        let epoch = CloudCarrierKey.epoch(userID: userID)
        return CloudCarrierDialer.ffi(apiBase: config.baseURL, teamID: nil, deviceName: deviceName,
                                      accessToken: { forceRefresh in
                                          do {
                                              return try await api.accessToken(forceRefresh)
                                          } catch where signedOut(error) || LinkController.authRefused(error) {
                                              throw LinkError(code: LinkError.unauthorized, message: "signed out")
                                          }
                                      },
                                      noiseKey: {
                                          try CloudCarrierKey.load(userID: userID, epoch: epoch, store: secrets,
                                                                   newKey: CloudCarrierDialer.newNoiseKey)
                                      })
    }
}

extension CloudRefusal {
    /// How long a machine without a daemon key waits for its list to change before the next
    /// list read lets the phone dial it again (one grant a minute at most).
    static let noDaemonKeyHold: Duration = .seconds(60)

    /// Whether `machine`, as the list shows it now, lifts the refusal. Paused or gone: the list
    /// is the truth once it no longer says running. No daemon key yet: the machine's state moved
    /// (it restarted: its status or availability changed), or a list read after
    /// `noDaemonKeyHold`. Only state counts: its last-active time moves on its own (the
    /// phone's own asks touch it), and lifting on that would ask for grants at every read.
    /// Others hold until Retry.
    func lifted(by machine: MacDevice, now: ContinuousClock.Instant) -> Bool {
        switch code {
        case "cloud.machine.paused", "cloud.machine.not_found": machine.cloud?.status != .running
        // A daemon that failed the handshake or the carrier: a machine that stopped and ran again
        // (started, rebuilt) may have a new daemon, so its status moving lifts it.
        case "carrier.handshake", "carrier.failed":
            machine.cloud?.status != listed?.cloud?.status
        case CloudCarrierDialer.noDaemonKey:
            machine.cloud?.status != listed?.cloud?.status || machine.isOnline != listed?.isOnline
                || now - at >= Self.noDaemonKeyHold
        default: false
        }
    }

    /// The line's words (never a vendor or a raw code).
    static func note(_ code: String, machine: String) -> String {
        switch code {
        case "carrier.handshake": "\(machine) didn't prove it's yours. Retry, or check it on your Mac."
        case "cloud.machine.paused": "\(machine) paused."
        case "cloud.machine.not_found": "\(machine) is gone."
        case "auth.forbidden": "Your account can't open \(machine)."
        case "feature.disabled": "Your administrator turned off cmux Cloud."
        case LinkError.unauthorized: "Sign in again to open \(machine)."
        case CloudCarrierDialer.noDaemonKey: "\(machine) is still starting up."
        case CloudCarrierDialer.keychainUnavailable: "This iPhone's Keychain can't keep the key for Cloud machines."
        default: "Couldn't connect to \(machine)."
        }
    }
}

#endif
