public import Foundation

/// The live ``McpServersServing``: each request is one short person-proven connection to this
/// app's acpmux (``AcpmuxPersonLine``), opened by `open`, used once and closed. acpmux answers
/// these methods only on a person connection, so a line whose proof was refused fails with
/// ``McpServersFailure/unavailable`` and sends nothing.
///
/// The key of ``setKey(_:connection:)`` goes only into the request frame; the line never logs a
/// frame, and this type keeps no copy.
@MainActor
public final class AcpmuxMcpServersService: McpServersServing {
    private let open: @MainActor () async -> AcpmuxPersonLine?

    /// - Parameter open: Opens a person line to this app's acpmux (nil when none answers), as
    ///   `AcpmuxPersonLine.open(environment)`.
    public init(open: @escaping @MainActor () async -> AcpmuxPersonLine?) {
        self.open = open
    }

    public func connections() async throws -> [McpServerConnection] {
        let result = try await call("_acpmux/mcp_connections", [:])
        return Self.connections(from: result)
    }

    public func setPolicy(_ policy: McpToolPolicy, tool: String, connection: String) async throws {
        _ = try await call("_acpmux/mcp_policy", ["id": connection, "tool": tool, "policy": policy.rawValue])
    }

    public func remove(connection: String) async throws {
        _ = try await call("_acpmux/mcp_remove", ["id": connection])
    }

    public func signIn(connection: String) async throws -> URL {
        let result = try await call("_acpmux/mcp_sign_in", ["id": connection])
        guard let url = Self.authorizeURL(from: result) else { throw McpServersFailure.refused }
        return url
    }

    public func setKey(_ key: String, connection: String) async throws -> McpKeyOutcome {
        let result = try await call("_acpmux/mcp_set_key", ["id": connection, "key": key])
        return result["connect"] as? String == "connected" ? .connected : .refused
    }

    public func approveTools(connection: String) async throws -> [String] {
        let result = try await call("_acpmux/mcp_approve_tools", ["id": connection])
        return (result["approved"] as? [Any] ?? []).compactMap { $0 as? String }
    }

    public func audit(limit: Int) async throws -> [String] {
        let result = try await call("_acpmux/mcp_audit", ["limit": max(1, min(limit, 1000))])
        return Self.auditLines(from: result)
    }

    /// The rows of an `_acpmux/mcp_connections` result.
    nonisolated static func connections(from result: [String: Any]) -> [McpServerConnection] {
        (result["connections"] as? [[String: Any]] ?? []).compactMap(McpServerConnection.init(row:))
    }

    /// The `authorizeUrl` of an `_acpmux/mcp_sign_in` result: an `https` URL only (a loopback
    /// `http` one too, for a local test server), never another scheme.
    nonisolated static func authorizeURL(from result: [String: Any]) -> URL? {
        guard let text = result["authorizeUrl"] as? String, let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), url.host?.isEmpty == false else { return nil }
        if scheme == "https" { return url }
        if scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? "") { return url }
        return nil
    }

    /// The lines of an `_acpmux/mcp_audit` result, each one compact JSON with sorted keys.
    nonisolated static func auditLines(from result: [String: Any]) -> [String] {
        (result["lines"] as? [Any] ?? []).compactMap { line in
            guard JSONSerialization.isValidJSONObject(line),
                  let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes])
            else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    private func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        guard let line = await open() else { throw McpServersFailure.unavailable }
        defer { line.close() }
        guard line.isPerson else { throw McpServersFailure.unavailable }
        guard let result = await line.call(method, params) else { throw McpServersFailure.refused }
        return result
    }
}
