import Foundation
import Testing
@testable import CmuxRemoteWorkspace

/// Alias-mapping rewriter: maps top-level `workspace_id` / `surface_id`
/// through the relay alias maps and stamps relay provenance, mirroring the
/// app-side rewriter closely enough to observe what reaches the local socket.
private struct AliasMappingRewriter: RemoteRelayCommandRewriting {
    let ownerWorkspaceID: UUID

    func rewriteRemoteRelayCommandLine(
        _ commandLine: Data,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) -> Data {
        guard let line = String(data: commandLine, encoding: .utf8),
              let data = line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              var request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return commandLine
        }
        var params = request["params"] as? [String: Any] ?? [:]
        if let raw = params["workspace_id"] as? String, let id = UUID(uuidString: raw),
           let mapped = workspaceAliases[id] {
            params["workspace_id"] = mapped.uuidString
        }
        if let raw = params["surface_id"] as? String, let id = UUID(uuidString: raw),
           let mapped = surfaceAliases[id] {
            params["surface_id"] = mapped.uuidString
        }
        params["_cmux_remote_workspace_id"] = ownerWorkspaceID.uuidString
        params["_cmux_remote_relay_request_authentication_code"] = "test"
        request["params"] = params
        guard let rewritten = try? JSONSerialization.data(withJSONObject: request) else {
            return commandLine
        }
        return rewritten + Data([0x0A])
    }
}

/// End-to-end relay scoping: an authenticated remote can reach only the
/// allowlisted methods, only on objects in its alias map, and never with
/// command-bearing parameters.
@Suite("Remote relay target scope", .serialized)
struct RemoteRelayTargetScopeTests {
    private let tokenHex = "00112233445566778899aabbccddeeff"
    private let relayID = "relay-target-scope"

    // Remote-issued IDs (from a restored snapshot) and the live local IDs they map to.
    private let remoteWorkspace = UUID()
    private let localWorkspace = UUID()
    private let remoteSurface = UUID()
    private let localSurface = UUID()
    // A purely local workspace/surface the relay does not own.
    private let foreignWorkspace = UUID()
    private let foreignSurface = UUID()

    @Test("methods outside the relay allowlist are rejected", arguments: [
        "workspace.create", "surface.create", "surface.respawn", "surface.send_key",
        "surface.resume.set", "system.exec", "browser.open", "feed.push", "workspace.select",
    ])
    func disallowedMethodIsRejected(method: String) throws {
        try withServer { port, unixServer in
            let request: [String: Any] = [
                "id": "deny-\(method)",
                "method": method,
                "params": [
                    "workspace_id": remoteWorkspace.uuidString,
                    "surface_id": remoteSurface.uuidString,
                ],
            ]
            let exchange = try exchange(port: port, request: request)
            expectDenial(exchange, unixServer, method)
        }
    }

    @Test("unmapped local workspace and surface IDs are rejected, not passed through", arguments: [
        ("surface.report_tty", ["tty_name": "/dev/ttys001"]),
        ("notification.create_for_target", ["title": "t"]),
        ("surface.read_text", [:]),
        ("terminal.paste", ["text": "id", "submit_key": "return"]),
        ("surface.send_text", ["text": "id\n"]),
    ] as [(String, [String: String])])
    func unmappedIDsAreRejected(method: String, extra: [String: String]) throws {
        try withServer { port, unixServer in
            // Foreign surface inside an owned workspace.
            var surfaceParams: [String: Any] = extra
            surfaceParams["workspace_id"] = remoteWorkspace.uuidString
            surfaceParams["surface_id"] = foreignSurface.uuidString
            expectDenial(
                try exchange(port: port, request: ["id": "s", "method": method, "params": surfaceParams]),
                unixServer,
                "\(method) foreign surface"
            )
            // Foreign workspace with an owned surface.
            var workspaceParams: [String: Any] = extra
            workspaceParams["workspace_id"] = foreignWorkspace.uuidString
            workspaceParams["surface_id"] = remoteSurface.uuidString
            expectDenial(
                try exchange(port: port, request: ["id": "w", "method": method, "params": workspaceParams]),
                unixServer,
                "\(method) foreign workspace"
            )
            // The live local ID itself is not an alias key unless the map says so.
            var localParams: [String: Any] = extra
            localParams["workspace_id"] = localWorkspace.uuidString
            localParams["surface_id"] = localSurface.uuidString
            expectDenial(
                try exchange(port: port, request: ["id": "l", "method": method, "params": localParams]),
                unixServer,
                "\(method) unmapped local ids"
            )
        }
    }

    @Test("allowed method with mapped IDs is rewritten and forwarded")
    func mappedRequestIsRewrittenAndForwarded() throws {
        try withServer { port, unixServer in
            let request: [String: Any] = [
                "id": "ok",
                "method": "surface.report_tty",
                "params": [
                    "workspace_id": remoteWorkspace.uuidString,
                    "surface_id": remoteSurface.uuidString,
                    "tty_name": "/dev/ttys001",
                ],
            ]
            let result = try exchange(port: port, request: request)
            #expect(result.responseLines.first?["ok"] as? Bool == true, "\(result.rawResponse)")
            #expect(unixServer.requests.count == 1)
            let forwardedData = try #require(unixServer.requests.first)
            let forwarded = try #require(
                try JSONSerialization.jsonObject(with: forwardedData) as? [String: Any]
            )
            let params = try #require(forwarded["params"] as? [String: Any])
            #expect(forwarded["method"] as? String == "surface.report_tty")
            #expect(params["workspace_id"] as? String == localWorkspace.uuidString)
            #expect(params["surface_id"] as? String == localSurface.uuidString)
            #expect(params["_cmux_remote_workspace_id"] as? String == localWorkspace.uuidString)
        }
    }

    @Test("command-bearing creation and respawn are rejected even on owned targets", arguments: [
        ("workspace.create", "initial_command"),
        ("surface.create", "initial_command"),
        ("surface.split", "initial_command"),
        ("surface.respawn", "command"),
        ("surface.report_tty", "initial_command"),
        ("surface.send_text", "command"),
    ])
    func commandBearingRequestsAreRejected(method: String, key: String) throws {
        try withServer { port, unixServer in
            let request: [String: Any] = [
                "id": "cmd",
                "method": method,
                "params": [
                    "workspace_id": remoteWorkspace.uuidString,
                    "surface_id": remoteSurface.uuidString,
                    "text": "x",
                    "tty_name": "/dev/ttys001",
                    key: "touch /tmp/relay-scope-test",
                ],
            ]
            expectDenial(try exchange(port: port, request: request), unixServer, "\(method).\(key)")
        }
    }

    @Test("a raw rpc passthrough is bounded by the same allowlist")
    func rawPassthroughIsBounded() throws {
        try withServer { port, unixServer in
            for line in [
                #"{"id":1,"method":"workspace.create","params":{"initial_command":"touch /tmp/x"}}"#,
                #"{"id":2,"method":"surface.respawn","params":{"command":"touch /tmp/x"}}"#,
                #"{"id":3,"method":"surface.send_key","params":{"key":"enter"}}"#,
                "new_workspace --command 'touch /tmp/x'",
            ] {
                let result = try runPolicyRelayExchange(
                    port: port, relayID: relayID, tokenHex: tokenHex, commandLine: line
                )
                expectDenial(result, unixServer, line)
            }
        }
    }

    private func exchange(port: Int, request: [String: Any]) throws -> PolicyRelayExchange {
        let data = try JSONSerialization.data(withJSONObject: request)
        return try runPolicyRelayExchange(
            port: port,
            relayID: relayID,
            tokenHex: tokenHex,
            commandLine: String(decoding: data, as: UTF8.self)
        )
    }

    private func expectDenial(
        _ exchange: PolicyRelayExchange,
        _ unixServer: PolicyFakeUnixSocketServer,
        _ label: String
    ) {
        let response = exchange.responseLines.first
        #expect(response?["ok"] as? Bool == false, "\(label): expected denial, got \(exchange.rawResponse)")
        #expect(
            (response?["error"] as? [String: Any])?["code"] as? String == "remote_relay_denied",
            "\(label): expected remote_relay_denied, got \(exchange.rawResponse)"
        )
        #expect(unixServer.requests.isEmpty, "\(label): denied command must not reach the local socket")
    }

    private func withServer(_ body: (Int, PolicyFakeUnixSocketServer) throws -> Void) throws {
        let unixServer = try PolicyFakeUnixSocketServer()
        defer { unixServer.close() }
        let server = try RemoteCLIRelayServer(
            localSocketPath: unixServer.path,
            relayID: relayID,
            relayTokenHex: tokenHex,
            commandRewriter: AliasMappingRewriter(ownerWorkspaceID: localWorkspace)
        )
        defer { server.stop() }
        server.updateRemoteRelayIDAliases(
            workspaceAliases: [remoteWorkspace: localWorkspace],
            surfaceAliases: [remoteSurface: localSurface]
        )
        let port = try server.start()
        try body(port, unixServer)
    }
}
