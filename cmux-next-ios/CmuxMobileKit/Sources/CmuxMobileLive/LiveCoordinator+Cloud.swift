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
        return store.cloudMachines.filter { $0.isOnline && cloudRefusals[$0.id] == nil }
    }

    /// The account's Cloud machines (`cloud.machine.list`, as `LiveCloudWorkspaces` reads it):
    /// listed beside the Macs, the running ones dialed lazily like Macs. A machine that left
    /// the list (deleted) closes its link and its rows go; one that stopped running closes
    /// its link and keeps its rows as last known.
    public func applyCloudMachines(_ machines: [MacDevice]) {
        let machines = machines.filter(\.isCloud)
        let before = Set(listedCloudMachines.map(\.id))
        listedCloudMachines = machines
        // A refusal that the list has since changed (paused, gone, started again) no longer holds.
        for (id, refusal) in cloudRefusals {
            guard let machine = machines.first(where: { $0.id == id }) else {
                cloudRefusals[id] = nil
                continue
            }
            if refusal.lifted(by: machine, now: .now) { cloudRefusals[id] = nil }
        }
        publishCloudMachines()
        let ids = Set(machines.map(\.id))
        for gone in before.subtracting(ids) {
            closeSession(gone)
            store.replaceWorkspaces(macID: gone, with: [])
            store.macData[gone] = nil
            lastShown[gone] = nil
        }
        for machine in machines where !machine.isOnline && sessions[machine.id] != nil {
            closeSession(machine.id)
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
        publishCloudMachines()
        applyLinks()
        onCloudRefusal?(machineID, error.code)
    }

    /// Whether the carrier refused this machine (Retry clears it).
    public func isCloudRefused(_ machineID: String) -> Bool { cloudRefusals[machineID] != nil }

    /// Retry on a machine its carrier refused (or whose session was signed out): a new session
    /// and link dial it now. The old one may be in `signedOut`, which never dials again.
    public func retryCloud(_ machineID: String) {
        cloudRefusals[machineID] = nil
        closeSession(machineID)
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

    /// Closes `session`'s link. A Cloud machine's terminals on screen release their sizes first
    /// (answered, bounded), so the machine never keeps this phone's grid after the carrier goes.
    func closeLink(_ session: MacSession) {
        guard session.isCloud else { return session.link.send(.target(nil)) }
        let terminals = session.terminals.compactMap(\.session)
        let link = session.link
        guard !terminals.isEmpty, link.phase.isConnected else { return link.send(.target(nil)) }
        // task-owner: bounded by each release's own 2 s deadline, then the close
        Task { @MainActor in
            for terminal in terminals { await terminal.releaseBeforeLinkCloses() }
            link.send(.target(nil))
        }
    }

    /// A Cloud machine's daemon is serving its workspaces on this phone now.
    public func cloudDaemonReady(_ machineID: String) -> Bool {
        guard let session = sessions[machineID] else { return false }
        return session.creation.canCreate(on: machineID)
    }

    /// The account's Cloud carrier dialer for this build: nil when it has no Cloud service.
    public static func standardCloudDialer(userID: String, deviceName: String, api: LiveAPI,
                                           secrets: any DeviceSecretStore = KeychainSecretStore()) -> (any MacLinkDialer)? {
        guard let config = ChiefCloudConfig.current() else { return nil }
        // Account-default scope, as the machine list reads it (no `x-cmux-team`): the phone's
        // active team is a Mac team (`personal-…` or a Stack id), not a Cloud `team_…` id.
        return CloudCarrierDialer.ffi(apiBase: config.baseURL, teamID: nil, deviceName: deviceName,
                                      accessToken: { try await api.accessToken($0) },
                                      noiseKey: { try CloudCarrierKey.load(userID: userID, store: secrets, newKey: CloudCarrierDialer.newNoiseKey) })
    }
}

extension CloudRefusal {
    /// How long a machine without a daemon key waits for its list to change before the next
    /// list read lets the phone dial it again (one grant a minute at most).
    static let noDaemonKeyHold: Duration = .seconds(60)

    /// Whether `machine`, as the list shows it now, lifts the refusal. Paused or gone: the list
    /// is the truth once it no longer says running. No daemon key yet: any change to the
    /// machine's listing, or a list read after `noDaemonKeyHold`. Others hold until Retry.
    func lifted(by machine: MacDevice, now: ContinuousClock.Instant) -> Bool {
        switch code {
        case "cloud.machine.paused", "cloud.machine.not_found": machine.cloud?.status != .running
        case CloudCarrierDialer.noDaemonKey: machine != listed || now - at >= Self.noDaemonKeyHold
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
        default: "Couldn't connect to \(machine)."
        }
    }
}

#endif
