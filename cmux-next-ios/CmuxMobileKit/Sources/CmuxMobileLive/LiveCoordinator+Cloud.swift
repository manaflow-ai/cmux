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
            if CloudRefusal.clearsWithList(refusal.code), machine.cloud?.status != .running { cloudRefusals[id] = nil }
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
        let name = listedCloudMachines.first { $0.id == machineID }?.name ?? "this Cloud machine"
        log.error("cloud carrier refused: \(error.code, privacy: .public)")
        cloudRefusals[machineID] = CloudRefusal(code: error.code, note: CloudRefusal.note(error.code, machine: name))
        publishCloudMachines()
        applyLinks()
        onCloudRefusal?(machineID, error.code)
    }

    /// Whether the carrier refused this machine (Retry clears it).
    public func isCloudRefused(_ machineID: String) -> Bool { cloudRefusals[machineID] != nil }

    /// Retry on a machine its carrier refused: dial it again now.
    public func retryCloud(_ machineID: String) {
        cloudRefusals[machineID] = nil
        publishCloudMachines()
        touch(machineID)
        if let session = sessions[machineID], session.link.target != nil { retry(macID: machineID) }
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
        return CloudCarrierDialer.ffi(apiBase: config.baseURL, teamID: nil, deviceName: deviceName,
                                      noiseKey: { try CloudCarrierKey.load(userID: userID, store: secrets, newKey: CloudCarrierDialer.newNoiseKey) },
                                      accessToken: { try await api.accessToken($0) })
    }
}

extension CloudRefusal {
    /// Paused or gone: the machine list is the truth, and its next change lifts the refusal.
    static func clearsWithList(_ code: String) -> Bool {
        code == "cloud.machine.paused" || code == "cloud.machine.not_found"
    }

    /// The line's words (never a vendor or a raw code).
    static func note(_ code: String, machine: String) -> String {
        switch code {
        case "carrier.handshake": "\(machine) didn't prove it's yours. Retry, or check it on your Mac."
        case "cloud.machine.paused": "\(machine) paused."
        case "cloud.machine.not_found": "\(machine) is gone."
        case "auth.forbidden": "Your account can't open \(machine)."
        case "feature.disabled": "Your administrator turned off cmux Cloud."
        default: "Couldn't connect to \(machine)."
        }
    }
}

#endif
