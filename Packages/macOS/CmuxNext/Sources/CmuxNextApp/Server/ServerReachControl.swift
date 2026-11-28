import CmuxNextControl
import CmuxNextSettings
import Foundation

/// Verification of the server reach on the debug socket.
///
/// - `debug.server_reach {refresh?}`: the shown servers (host, name, route,
///   link and daemon state, workspace names) and the last plan; `refresh`
///   runs one read first.
/// - DEV builds only (placing a chief is a user act, never a local
///   process's): `debug.server_reach.test_chief {host, install, display_name}`
///   creates a NON-default chief placed on a paired server (a test brain),
///   and `debug.server_reach.cleanup {host, chief?}` archives that chief and
///   revokes the server (`server.revoke`). Both go to the API Worker as the
///   signed-in user with origin `user`.
enum ServerReachControl {
    static func methods(services: AppServices) -> [ControlMethod] {
        var methods: [ControlMethod] = [
            .async("debug.server_reach") { [weak services] call in
                guard let services else { throw ControlError(code: "unavailable", message: "no services") }
                if call.params["refresh"]?.boolValue == true { await reach(services).read() }
                return await MainActor.run { report(services) }
            }.withDeadline(.fixed(.seconds(40))),
        ]
        guard ControlService.isDebugBuild else { return methods }
        methods += [
            .async("debug.server_reach.test_chief") { [weak services] call in
                guard let services else { throw ControlError(code: "unavailable", message: "no services") }
                guard let host = call.params["host"]?.stringValue, let install = call.params["install"]?.stringValue else {
                    throw ControlError.invalidParams("needs host and install")
                }
                let name = call.params["display_name"]?.stringValue ?? "Test Chief"
                let body: [String: Any] = ["op": "chief.create", "origin": "user", "idempotency_key": "test-chief-\(host)-\(install)",
                                           "params": ["display_name": name, "is_default": false,
                                                      "brain_place": ["host": host, "install": install]]]
                let value = try await owner(services, "v1/ops", body)
                await reach(services).read()
                return value
            }.withDeadline(.fixed(.seconds(60))),
            .async("debug.server_reach.cleanup") { [weak services] call in
                guard let services else { throw ControlError(code: "unavailable", message: "no services") }
                guard let host = call.params["host"]?.stringValue else { throw ControlError.invalidParams("needs host") }
                var out: [String: JSONValue] = [:]
                if let chief = call.params["chief"]?.stringValue {
                    // chief.archive needs the chief's current revision.
                    let rev = try await chiefRevision(services, chief)
                    if let rev {
                        out["chief"] = try await owner(services, "v1/ops", ["op": "chief.archive", "origin": "user",
                                                                            "idempotency_key": "test-chief-archive-\(chief)-\(rev)",
                                                                            "params": ["chief": chief, "expected_rev": rev]])
                    } else {
                        out["chief"] = .string("not listed (already archived or unknown)")
                    }
                }
                out["revoke"] = try await owner(services, "v1/ops", ["op": "server.revoke", "origin": "user", "idempotency_key": "test-server-revoke-\(host)",
                                                                     "params": ["host": host]])
                await reach(services).read()
                out["servers"] = await MainActor.run { report(services) }
                return .object(out)
            }.withDeadline(.fixed(.seconds(60))),
        ]
        return methods
    }

    /// The chief's current revision, or nil when `chief.list` does not list it.
    @MainActor
    private static func chiefRevision(_ services: AppServices, _ chief: String) async throws -> Int? {
        let feed = services.feed
        return try await CloudChiefs.list { path, body in try await feed.call(path, body) }.first { $0.id == chief }?.rev
    }

    @MainActor
    private static func reach(_ services: AppServices) -> ServerReachService { services.serverReach }

    @MainActor
    private static func owner(_ services: AppServices, _ path: String, _ body: [String: Any]) async throws -> JSONValue {
        do {
            return JSONValue(foundation: try await services.feed.call(path, body)["value"] ?? NSNull()) ?? .null
        } catch let FeedServiceError.owner(code, message) {
            throw ControlError(code: code, message: message)
        } catch {
            throw ControlError(code: "owner.unreachable", message: String(describing: error))
        }
    }

    @MainActor
    static func report(_ services: AppServices) -> JSONValue {
        let machines = services.machines
        let servers: [JSONValue] = machines.servers.map { server in
            let header = server.sidebarMachine(machines: machines)
            let route: String = switch server.reach.route {
            case .ssh(let host): "ssh \(host.destination.description)"
            case .unix(let path): "unix \(path)"
            case .overlay(let socket): "overlay \(socket)"
            }
            return .object([
                "machine": .string(server.machineID), "host": .string(server.reach.hostID), "name": .string(server.name),
                "route": .string(route), "status": .string(String(describing: header.status)),
                "session": server.daemon.identity?.sessionID.map(JSONValue.string) ?? .null,
                "reason": server.notConnectedReason.map(JSONValue.string) ?? .null,
                "workspaces": .array(server.daemon.store.workspaces.map { .string($0.title ?? $0.name) }),
            ])
        }
        let plan = services.serverReach.lastPlan
        return .object([
            "servers": .array(servers),
            "desired": .array((plan?.desired ?? []).map { .string($0.hostID) }),
            "unroutable": .array((plan?.unroutable ?? []).map(JSONValue.string)),
        ])
    }
}
