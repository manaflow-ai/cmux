import CmuxNextCloud
import Foundation
import os

extension CloudService {
    private var machineMutations: CloudMachineMutations {
        let api = api, scope = teamScope, selection = cloudTeam
        return CloudMachineMutations(appServer: configuration.linkSource == .appServer,
            snapshot: { try await scope.snapshot() }, ops: { self.appOps($0) }, check: { try selection.check($0) },
            legacy: { mutation, machine in
                switch mutation {
                case .delete: try await api.deleteMachine(machine)
                case .pause: try await api.pauseMachine(machine)
                case .resume: try await api.resumeMachine(machine)
                case .rename(let name): try await api.renameMachine(machine, to: name.isEmpty ? nil : name)
                }
            })
    }

    func deleteMachine(_ machineID: String, origin: CloudLinkOrigin) async throws {
        try await machineMutations.run(.delete, machine: machineID, origin: origin) {
            creations.machineRemoved(machineID)
            machines.remove(machineID)?.disconnect()
        }
        logger.info("deleted machine \(machineID, privacy: .public)")
    }

    func pauseMachine(_ machineID: String, origin: CloudLinkOrigin) async throws {
        try await machineMutations.run(.pause, machine: machineID, origin: origin) { }
        await refresh()
        logger.info("paused machine \(machineID, privacy: .public)")
    }

    func resumeMachine(_ machineID: String, origin: CloudLinkOrigin) async throws {
        try await machineMutations.run(.resume, machine: machineID, origin: origin) { }
        await refresh()
        logger.info("resumed machine \(machineID, privacy: .public)")
    }

    func renameMachine(_ machineID: String, to name: String, origin: CloudLinkOrigin) async throws {
        try await machineMutations.run(.rename(name), machine: machineID, origin: origin) {
            machines.session(machineID)?.machine.displayName = name.isEmpty ? nil : name
        }
    }
}
