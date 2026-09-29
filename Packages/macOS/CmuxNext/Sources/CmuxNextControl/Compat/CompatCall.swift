import CmuxNextDaemon
import Foundation

/// One compat request as a handler sees it.
struct CompatCall: Sendable {
    let service: CompatService
    let control: ControlCall

    var method: String { control.method }
    var params: [String: JSON] { control.params }

    /// The world as of the published snapshot (read lane; never waits).
    func snapshotWorld() throws -> CompatWorld {
        let topology = control.snapshot.topology
        guard topology.isLoaded else {
            throw ControlError(code: "unavailable", message: ControlStrings.format("control.error.treeNotLoaded", "cmux-next has not loaded the cmux-tui tree yet (daemon %@)", "\(topology.daemonState)"))
        }
        return CompatWorld(topology: topology, refs: service.refs)
    }

    /// The world from a fresh `list-workspaces`, joined with the snapshot's
    /// app-local state: read-your-writes for mutations.
    func world() async throws -> CompatWorld {
        let tree = try await service.daemon("list-workspaces") { try await $0.listWorkspaces() }
        return CompatWorld(topology: CompatFreshTopology.make(tree: tree, appState: control.snapshot.topology), refs: service.refs)
    }

    func target(_ world: CompatWorld) -> CompatTarget { CompatTarget(world: world, refs: service.refs, params: params) }

    @discardableResult
    func perform(_ intent: CompatFrontendIntent) async throws -> JSON {
        try await service.perform(intent, connection: control.connection, method: method, deadline: control.deadline)
    }

    func string(_ key: String) -> String? {
        guard let value = params[key], !value.isNull else { return nil }
        return value.stringValue ?? value.compactText
    }

    func bool(_ key: String) -> Bool? {
        guard let value = params[key] else { return nil }
        if let flag = value.boolValue { return flag }
        switch value.stringValue?.lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return value.intValue.map { $0 != 0 }
        }
    }

    func int(_ key: String) -> Int? {
        params[key]?.intValue ?? params[key]?.stringValue.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    func require(_ key: String) throws -> String {
        guard let value = string(key), !value.isEmpty else { throw CompatErrors.missing(key, method) }
        return value
    }

    /// Old-app `focus` param: default false for creation verbs (no focus steal).
    var wantsFocus: Bool { bool("focus") ?? false }
}
