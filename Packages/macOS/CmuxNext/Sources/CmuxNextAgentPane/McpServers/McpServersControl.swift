import CmuxNextControl
import CmuxNextSettings
import Foundation

/// The control methods behind `cmux mcp ls|tools|audit|rm|auth|key|policy|approve-tools`
/// (plans/cmux-next/mcp-connect-DESIGN.md row 3c). An agent can run the CLI, so the CLI never adds
/// trust: it reads, it removes (less access), or it opens Settings > MCP Servers at a connection,
/// where the person clicks. The app relays to acpmux on its person line
/// (``McpServersCoordinator/service``); no method here sets a policy, signs in, takes a key or
/// approves held tools.
///
/// - `mcp.servers.list {}`: `{connections: [{id, name, title, publisher, verified, url, auth,
///   hasSecret, scope, state, addedAt, tools: [{name, policy}], held: [name]}]}`, never a secret.
/// - `mcp.servers.audit {limit?}`: `{lines: [...]}`, the newest audit lines (digests only).
/// - `mcp.servers.remove {connection}`: removes the connection a name or id names; `{removed, name}`.
/// - `mcp.servers.open {connection?, focus?}`: shows the MCP Servers tab with that connection
///   selected; `focus` false opens it without selecting the tab.
struct McpServersControl {
    weak var coordinator: McpServersCoordinator?

    func methods() -> [ControlMethod] {
        let coordinator = coordinator
        return [
            .async("mcp.servers.list") { [weak coordinator] _ in
                try await Self.list(coordinator)
            }.withDeadline(.fixed(.seconds(20))),
            .async("mcp.servers.audit") { [weak coordinator] call in
                try await Self.audit(coordinator, limit: call.params["limit"]?.intValue)
            }.withDeadline(.fixed(.seconds(20))),
            .async("mcp.servers.remove") { [weak coordinator] call in
                guard let reference = call.params["connection"]?.stringValue, !reference.isEmpty else {
                    throw ControlError.invalidParams("mcp.servers.remove needs `connection` (a name or id).")
                }
                return try await Self.remove(coordinator, reference: reference)
            }.withDeadline(.fixed(.seconds(20))),
            .mainActor("mcp.servers.open") { [weak coordinator] call in
                guard let coordinator else { return .value(.null) }
                let reference = call.params["connection"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                guard coordinator.show(connection: reference, focus: call.params["focus"]?.boolValue ?? true) else {
                    throw ControlError.invalidParams(McpServersStrings.noWindow)
                }
                return .value(["opened": true])
            },
        ]
    }

    static func list(_ coordinator: McpServersCoordinator?) async throws -> JSONValue {
        let service = try serviceOf(coordinator)
        let rows = try await relay { try await service.connections() }
        return .object(["connections": .array(rows.map(json))])
    }

    static func audit(_ coordinator: McpServersCoordinator?, limit: Int?) async throws -> JSONValue {
        let service = try serviceOf(coordinator)
        let limit = limit.map { max(1, min($0, 1000)) } ?? McpServersModel.auditLimit
        let lines = try await relay { try await service.audit(limit: limit) }
        return .object(["lines": .array(lines.map(Self.auditLine))])
    }

    static func remove(_ coordinator: McpServersCoordinator?, reference: String) async throws -> JSONValue {
        let service = try serviceOf(coordinator)
        let rows = try await relay { try await service.connections() }
        guard let found = rows.first(where: { $0.matches(reference) }) else {
            throw ControlError(code: "not_found", message: "No MCP server is named \(reference).")
        }
        try await relay { try await service.remove(connection: found.id) }
        return .object(["removed": .string(found.id), "name": .string(found.name)])
    }

    /// One connection as the CLI prints it: the daemon's row, without anything secret.
    nonisolated static func json(_ connection: McpServerConnection) -> JSONValue {
        .object([
            "id": .string(connection.id), "name": .string(connection.name), "title": .string(connection.title),
            "publisher": .string(connection.publisher), "verified": .bool(connection.verified),
            "url": .string(connection.url), "auth": .string(connection.auth), "hasSecret": .bool(connection.hasSecret),
            "scope": .string(connection.scope), "state": .string(connection.state),
            "addedAt": .number(Double(connection.addedAt)),
            "tools": .array(connection.tools.map { .object(["name": .string($0.name), "policy": .string($0.policy.rawValue)]) }),
            "held": .array(connection.held.map { .string($0) }),
        ])
    }

    /// An audit line as JSON (the service hands compact JSON text).
    nonisolated static func auditLine(_ line: String) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))) ?? .string(line)
    }

    private static func serviceOf(_ coordinator: McpServersCoordinator?) throws -> any McpServersServing {
        guard let coordinator else { throw ControlError(code: "unavailable", message: "The app is closing.") }
        return coordinator.service
    }

    /// Runs one acpmux request and maps its failure to the CLI's error codes.
    private static func relay<T>(_ request: () async throws -> T) async throws -> T {
        do {
            return try await request()
        } catch McpServersFailure.unavailable {
            throw ControlError(code: "unavailable", message: "cmux could not reach its acpmux as the person.")
        } catch McpServersFailure.refused {
            throw ControlError(code: "mcp.refused", message: "acpmux refused the request.")
        }
    }
}
