import CmuxFoundation
import Foundation
import Testing
@testable import CmuxRemoteWorkspace

@Suite("RemoteCLIRelayPolicy", .serialized)
struct RemoteCLIRelayPolicyTests {
    private let tokenHex = "00112233445566778899aabbccddeeff"
    private let relayID = "relay-policy"

    @Test("core discovery uses canonical RPC names and the authenticated relay", arguments: [
        "system.ping", "system.capabilities", "workspace.list"
    ])
    func forwardsCoreDiscovery(method: String) throws {
        try withServer { port, unixServer in
            let exchange = try runPolicyRelayExchange(port: port, relayID: relayID,
                tokenHex: tokenHex, commandLine: "{\"id\":\"core\",\"method\":\"\(method)\",\"params\":{}}")
            #expect(exchange.responseLines.first?["ok"] as? Bool == true)
            #expect(unixServer.requests.count == 1)
        }
    }

    @Test("unsupported core aliases and malformed discovery never reach the Mac")
    func deniesUnsafeCoreDiscovery() throws {
        try withServer { port, unixServer in
            for request in [
                #"{"method":"ping","params":{}}"#,
                #"{"method":"capabilities","params":{}}"#,
                #"{"method":"workspace.list.extra","params":{}}"#,
                #"{"method":"workspace.list","params":{"window_id":"window:1"}}"#,
                #"{"method":"workspace.list","params":{"workspace_id":null}}"#,
                #"{"method":"workspace.list","params":{"workspace_ids":[]}}"#,
                #"{"method":"workspace.list","params":{"metadata":[{"command":"id"}]}}"#,
                #"{"method":"workspace.list","params":[]}"#,
                #"{"method":"workspace.list","params":"invalid"}"#,
                #"{"method":"workspace.list""#,
                "list_workspaces"
            ] {
                let exchange = try runPolicyRelayExchange(port: port, relayID: relayID,
                    tokenHex: tokenHex, commandLine: request)
                expectDenial(exchange, unixServer, request)
            }
        }
    }

    @Test("agent message methods allow targets owned by the remote session")
    func allowsOwnedAgentMessageTargets() throws {
        let workspace = UUID()
        let surface = UUID()
        try withServer(
            workspaceAliases: [workspace: workspace],
            surfaceAliases: [surface: surface]
        ) { port, unixServer in
            for (id, method, params) in [
                ("m1", "agent.message.poll", [
                    "surface_id": surface.uuidString,
                    "poller_key": "poller",
                ]),
                ("m2", "agent.message.claim", [
                    "surface_id": surface.uuidString,
                    "via": "hook",
                ]),
                ("m3", "agent.message.mark_read", [
                    "surface_id": surface.uuidString,
                ]),
                ("m4", "agent.message.list", [
                    "surface": surface.uuidString,
                ]),
                ("m5", "agent.message.send", [
                    "target": workspace.uuidString,
                    "body": "hello",
                ]),
            ] {
                let request: [String: Any] = [
                    "id": id,
                    "method": method,
                    "params": params,
                ]
                let data = try JSONSerialization.data(withJSONObject: request)
                let exchange = try runPolicyRelayExchange(
                    port: port,
                    relayID: relayID,
                    tokenHex: tokenHex,
                    commandLine: String(decoding: data, as: UTF8.self)
                )
                #expect(exchange.responseLines.first?["ok"] as? Bool == true, "\(method): \(exchange.rawResponse)")
            }
            #expect(unixServer.requests.count == 5)
        }
    }

    @Test("agent message send rejects an unowned target")
    func deniesUnownedAgentMessageTarget() throws {
        let ownedWorkspace = UUID()
        let unownedWorkspace = UUID()
        try withServer(workspaceAliases: [ownedWorkspace: ownedWorkspace]) { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: """
                {"id":"m6","method":"agent.message.send","params":{"target":"\(unownedWorkspace.uuidString)","body":"hello"}}
                """
            )
            expectDenial(exchange, unixServer, "unowned agent message target")
        }
    }

    @Test("agent message send requires a target")
    func deniesMissingAgentMessageTarget() throws {
        try withServer { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: #"{"id":"m7","method":"agent.message.send","params":{"body":"hello"}}"#
            )
            expectDenial(exchange, unixServer, "missing agent message target")
        }
    }

    @Test("agent message mark_read rejects unscoped message ids", arguments: ["id", "ids"])
    func deniesUnscopedAgentMessageIDs(key: String) throws {
        let surface = UUID()
        try withServer(surfaceAliases: [surface: surface]) { port, unixServer in
            let value: Any = key == "id" ? "message-id" : ["message-id"]
            let request: [String: Any] = [
                "id": "m8-\(key)",
                "method": "agent.message.mark_read",
                "params": [
                    "surface_id": surface.uuidString,
                    key: value,
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: request)
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: String(decoding: data, as: UTF8.self)
            )
            expectDenial(exchange, unixServer, "mark_read \(key)")
        }
    }

    @Test("agent message send rejects replies through the relay")
    func deniesAgentMessageReplyTo() throws {
        try withServer { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: #"{"id":"m9","method":"agent.message.send","params":{"reply_to":"message-id","body":"hello"}}"#
            )
            expectDenial(exchange, unixServer, "agent message reply_to")
        }
    }

    @Test("agent message send rejects spoofed sender ids", arguments: [
        "sender_surface_id", "sender_workspace_id"
    ])
    func deniesSpoofedAgentMessageSenderID(key: String) throws {
        let ownedWorkspace = UUID()
        let ownedSurface = UUID()
        let unownedID = UUID()
        try withServer(
            workspaceAliases: [ownedWorkspace: ownedWorkspace],
            surfaceAliases: [ownedSurface: ownedSurface]
        ) { port, unixServer in
            let request: [String: Any] = [
                "id": "m10-\(key)",
                "method": "agent.message.send",
                "params": [
                    "target": ownedWorkspace.uuidString,
                    "body": "hello",
                    key: unownedID.uuidString,
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: request)
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: String(decoding: data, as: UTF8.self)
            )
            expectDenial(exchange, unixServer, "spoofed \(key)")
        }
    }

    private func withServer(
        workspaceAliases: [UUID: UUID] = [:],
        surfaceAliases: [UUID: UUID] = [:],
        responseBody: Data = Data("{\"ok\":true,\"result\":{}}\n".utf8),
        _ body: (Int, PolicyFakeUnixSocketServer) throws -> Void
    ) throws {
        let unixServer = try PolicyFakeUnixSocketServer(responseBody: responseBody)
        defer { unixServer.close() }
        let server = try RemoteCLIRelayServer(
            localSocketPath: unixServer.path,
            relayID: relayID,
            relayTokenHex: tokenHex,
            commandRewriter: PolicyPassthroughRewriter()
        )
        defer { server.stop() }
        server.updateRemoteRelayIDAliases(
            workspaceAliases: workspaceAliases,
            surfaceAliases: surfaceAliases
        )
        // The alias update and every later connection acceptance are enqueued
        // on the relay's single serial queue in FIFO order, so the aliases are
        // guaranteed visible to any command rewrite that follows.
        let port = try server.start()
        try body(port, unixServer)
    }

    private func expectDenial(
        _ exchange: PolicyRelayExchange,
        _ unixServer: PolicyFakeUnixSocketServer,
        _ label: String
    ) {
        let response = exchange.responseLines.first
        #expect(response?["ok"] as? Bool == false, "\(label): expected ok:false denial, got \(exchange.rawResponse)")
        #expect(
            (response?["error"] as? [String: Any])?["code"] as? String == "remote_relay_denied",
            "\(label): expected remote_relay_denied error code, got \(exchange.rawResponse)"
        )
        #expect(unixServer.requests.isEmpty, "\(label): denied command must not reach the local socket")
    }

    @Test("workspace.create with initial_command is denied (GHSA-9vmv-3hjw-j28c)")
    func deniesWorkspaceCreateInitialCommand() throws {
        try withServer { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: #"{"id":"p1","method":"workspace.create","params":{"initial_command":"touch /tmp/pwned"}}"#
            )
            expectDenial(exchange, unixServer, "workspace.create initial_command")
        }
    }

    @Test("workspace.create is denied even without command params")
    func deniesWorkspaceCreate() throws {
        try withServer { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: #"{"id":"p2","method":"workspace.create","params":{"title":"x"}}"#
            )
            expectDenial(exchange, unixServer, "workspace.create")
        }
    }

    @Test("surface.send_text with a malformed surface selector is denied")
    func deniesUnmappedSurfaceSendText() throws {
        let alias = (remote: UUID(), local: UUID())
        try withServer(surfaceAliases: [alias.remote: alias.local]) { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: """
                {"id":"p3","method":"surface.send_text","params":{"surface_id":17,"text":"open https://example.com\\n"}}
                """
            )
            expectDenial(exchange, unixServer, "unmapped send_text")
        }
    }

    @Test("surface.send_text to an aliased remote surface is forwarded")
    func allowsAliasedSurfaceSendText() throws {
        let alias = (remote: UUID(), local: UUID())
        try withServer(surfaceAliases: [alias.remote: alias.local]) { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: """
                {"id":"p4","method":"surface.send_text","params":{"surface_id":"\(alias.remote.uuidString)","text":"ls\\n"}}
                """
            )
            #expect(exchange.responseLines.first?["ok"] as? Bool == true)
            #expect(unixServer.requests.count == 1)
        }
    }

    @Test("terminal.paste to an owned remote surface is forwarded")
    func allowsAliasedTerminalPaste() throws {
        let workspace = UUID()
        let surface = UUID()
        try withServer(
            workspaceAliases: [workspace: workspace],
            surfaceAliases: [surface: surface]
        ) { port, unixServer in
            for submitKey in ["none", "return"] {
                let exchange = try runPolicyRelayExchange(
                    port: port,
                    relayID: relayID,
                    tokenHex: tokenHex,
                    commandLine: """
                    {"id":"paste-\(submitKey)","method":"terminal.paste","params":{"workspace_id":"\(workspace.uuidString)","surface_id":"\(surface.uuidString)","text":"line one\\nline two","submit_key":"\(submitKey)"}}
                    """
                )
                #expect(exchange.responseLines.first?["ok"] as? Bool == true, "\(submitKey): \(exchange.rawResponse)")
            }
            #expect(unixServer.requests.count == 2)
        }
    }

    @Test("terminal.paste with command params, fallback selectors, or other submit keys is denied")
    func deniesUnsafeTerminalPaste() throws {
        let workspace = UUID()
        let surface = UUID()
        try withServer(
            workspaceAliases: [workspace: workspace],
            surfaceAliases: [surface: surface]
        ) { port, unixServer in
            let target = #""workspace_id":"\#(workspace.uuidString)","surface_id":"\#(surface.uuidString)""#
            for params in [
                #"{\#(target),"text":"x","submit_key":"none","command":"touch /tmp/pwned"}"#,
                #"{\#(target),"text":"x","submit_key":"none","initial_command":"touch /tmp/pwned"}"#,
                #"{\#(target),"text":"x","submit_key":"none","window_id":"window:1"}"#,
                #"{\#(target),"text":"x","submit_key":"ctrl+enter"}"#,
                #"{\#(target),"text":"x"}"#,
                #"{\#(target),"text":7,"submit_key":"none"}"#,
                #"{"workspace_id":"\#(workspace.uuidString)","surface_id":17,"text":"x","submit_key":"none"}"#,
            ] {
                let request = #"{"id":"paste-deny","method":"terminal.paste","params":\#(params)}"#
                let exchange = try runPolicyRelayExchange(
                    port: port,
                    relayID: relayID,
                    tokenHex: tokenHex,
                    commandLine: request
                )
                expectDenial(exchange, unixServer, request)
            }
        }
    }

    @Test("methods outside the relay allowlist are denied")
    func deniesNonAllowlistedMethod() throws {
        try withServer { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: #"{"id":"p5","method":"system.exec","params":{"command":"id"}}"#
            )
            expectDenial(exchange, unixServer, "non-allowlisted method")
        }
    }

    @Test("browser uploads cannot read local files through the remote relay")
    func deniesBrowserFileInputEvenOnOwnedSurface() throws {
        let alias = (remote: UUID(), local: UUID())
        try withServer(surfaceAliases: [alias.remote: alias.local]) { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: """
                {"id":"upload","method":"browser.set_input_files","params":{"surface_id":"\(alias.remote.uuidString)","selector":"input","files":["/tmp/private.csv"]}}
                """
            )
            expectDenial(exchange, unixServer, "local file upload through remote relay")
        }
    }

    /// `workspace.reorder` has no relay parameter contract, so the method gate
    /// denies it before any selector is read.
    ///
    /// The selectors below are UUIDs on purpose. Ref-form selectors such as
    /// `workspace:1` are rejected by the *selector* gate
    /// (`RemoteRelayCommandPolicy.malformedSelector`) whether or not the method
    /// is allowlisted, so a ref-form payload reports `remote_relay_denied`
    /// either way and this test would stay green through exactly the
    /// regression it exists to catch. With UUIDs, the method gate is the only
    /// thing left denying these, so allowlisting `workspace.reorder` turns them
    /// into `ALLOW` and fails the test.
    @Test("workspace.reorder has no relay contract")
    func workspaceReorderHasNoRelayContract() {
        #expect(
            RemoteRelayRoutingSchema().parameters(for: "workspace.reorder") == nil,
            "workspace.reorder must stay absent from the relay routing schema"
        )
    }

    @Test("workspace.reorder is denied through a relay", arguments: [
        #"{"id":"p5r","method":"workspace.reorder","params":{"workspace_id":"1EA7D9C4-0000-4000-8000-00000000A001","index":0}}"#,
        #"{"id":"p5r","method":"workspace.reorder","params":{"workspace_id":"1EA7D9C4-0000-4000-8000-00000000A001","before_workspace_id":"1EA7D9C4-0000-4000-8000-00000000A002"}}"#,
        #"{"id":"p5r","method":"workspace.reorder","params":{"workspace_id":"1EA7D9C4-0000-4000-8000-00000000A001","after_workspace_id":"1EA7D9C4-0000-4000-8000-00000000A002"}}"#,
    ])
    func deniesWorkspaceReorder(commandLine: String) throws {
        try withServer { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: commandLine
            )
            expectDenial(exchange, unixServer, "workspace.reorder")
        }
    }

    @Test("non-JSON command lines are denied")
    func deniesNonJSONCommandLine() throws {
        try withServer { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: "workspace.list {}"
            )
            expectDenial(exchange, unixServer, "non-JSON line")
        }
    }

    @Test("surface.respawn is denied even on an owned surface (local respawn fallback)")
    func deniesRespawnOnAliasedSurface() throws {
        // The app respawns a plain SSH remote surface locally under the same
        // surface ID, so relay-carried respawn would convert an owned surface
        // into a local shell the remote can drive. Deny the method outright.
        let alias = (remote: UUID(), local: UUID())
        try withServer(surfaceAliases: [alias.remote: alias.local]) { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: """
                {"id":"p6","method":"surface.respawn","params":{"surface_id":"\(alias.remote.uuidString)"}}
                """
            )
            expectDenial(exchange, unixServer, "respawn on owned surface")
        }
    }

    @Test("surface.respawn with a start command on an unmapped surface is denied")
    func deniesRespawnOnUnmappedSurface() throws {
        try withServer { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: """
                {"id":"p7","method":"surface.respawn","params":{"surface_id":"\(UUID().uuidString)","tmux_start_command":"/bin/sh -c id"}}
                """
            )
            expectDenial(exchange, unixServer, "unmapped respawn")
        }
    }

    @Test("surface.create without a remote target is denied")
    func deniesSurfaceCreateWithoutTarget() throws {
        try withServer { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: #"{"id":"p8","method":"surface.create","params":{"type":"terminal"}}"#
            )
            expectDenial(exchange, unixServer, "surface.create without target")
        }
    }

    @Test("surface.create is denied even on an aliased remote workspace")
    func allowsSurfaceCreateOnAliasedWorkspace() throws {
        let alias = (remote: UUID(), local: UUID())
        try withServer(workspaceAliases: [alias.remote: alias.local]) { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: """
                {"id":"p9","method":"surface.create","params":{"type":"terminal","workspace_id":"\(alias.remote.uuidString)"}}
                """
            )
            expectDenial(exchange, unixServer, "surface.create")
        }
    }

    @Test("workspace.group.delete is denied")
    func deniesWorkspaceGroupDelete() throws {
        try withServer { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: """
                {"id":"p10","method":"workspace.group.delete","params":{"group_id":"\(UUID().uuidString)","close_workspaces":true}}
                """
            )
            expectDenial(exchange, unixServer, "workspace.group.delete")
        }
    }

    @Test("window.create is denied")
    func deniesWindowCreate() throws {
        try withServer { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: #"{"id":"p11","method":"window.create","params":{}}"#
            )
            expectDenial(exchange, unixServer, "window.create")
        }
    }

    @Test("send_text to a live local ID from the alias values is forwarded (fresh-session shape)")
    func allowsAliasedLocalIDValueSendText() throws {
        // Fresh remote sessions carry no distinct remote IDs: the remote
        // shell's environment holds the workspace's live local UUIDs, and the
        // app syncs them as identity alias entries.
        let localSurface = UUID()
        try withServer(surfaceAliases: [localSurface: localSurface]) { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: """
                {"id":"p12","method":"surface.send_text","params":{"surface_id":"\(localSurface.uuidString)","text":"ls\\n"}}
                """
            )
            #expect(exchange.responseLines.first?["ok"] as? Bool == true)
            #expect(unixServer.requests.count == 1)
        }
    }

    @Test("lifecycle methods from remote bootstrap scripts are forwarded")
    func allowsLifecycleTerminalSessionLaunching() throws {
        let localWorkspace = UUID()
        try withServer(workspaceAliases: [localWorkspace: localWorkspace]) { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: """
                {"id":"p13","method":"workspace.remote.terminal_session_launching","params":{"workspace_id":"\(localWorkspace.uuidString)","terminal_lifecycle_id":"lc","attempt_id":"a1"}}
                """
            )
            #expect(exchange.responseLines.first?["ok"] as? Bool == true)
            #expect(unixServer.requests.count == 1)
        }
    }

    /// A relayed `create_for_target` with `effects` reaches the local socket with the override intact.
    @Test("notification.create_for_target carrying an effects override is forwarded")
    func allowsNotificationCreateForTargetWithEffects() throws {
        let localWorkspace = UUID()
        let localSurface = UUID()
        try withServer(
            workspaceAliases: [localWorkspace: localWorkspace],
            surfaceAliases: [localSurface: localSurface]
        ) { port, unixServer in
            let exchange = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: """
                {"id":"p15","method":"notification.create_for_target","params":{"workspace_id":"\(localWorkspace.uuidString)","surface_id":"\(localSurface.uuidString)","title":"Done","effects":{"desktop":false}}}
                """
            )
            #expect(exchange.responseLines.first?["ok"] as? Bool == true)
            #expect(unixServer.requests.count == 1)
            let forwarded = try #require(unixServer.requests.first)
            #expect(String(decoding: forwarded, as: UTF8.self).contains("\"effects\":{\"desktop\":false}"))
        }
    }

    @Test("relay does not learn ownership from unsolicited create responses")
    func createdSurfaceIsNotOwnedByResponse() throws {
        // The package relay never treats response fields as an ownership grant:
        // a surface ID that is absent from the alias map is refused before the
        // local socket, even when a prior response named it.
        let workspaceAlias = (remote: UUID(), local: UUID())
        let createdSurface = UUID()
        let createResponse = Data("""
        {"ok":true,"result":{"surface_id":"\(createdSurface.uuidString)","workspace_id":"\(workspaceAlias.local.uuidString)"}}

        """.utf8)
        try withServer(
            workspaceAliases: [workspaceAlias.remote: workspaceAlias.local],
            responseBody: createResponse
        ) { port, unixServer in
            let send = try runPolicyRelayExchange(
                port: port,
                relayID: relayID,
                tokenHex: tokenHex,
                commandLine: """
                {"id":"c2","method":"surface.send_text","params":{"surface_id":"\(createdSurface.uuidString)","text":"ls\\n"}}
                """
            )
            expectDenial(send, unixServer, "unowned created surface")
        }
    }

    @Test("the local socket stand-in survives a relay that abandons its round trip")
    func abandonedLocalRoundTripDoesNotKillTheTestProcess() throws {
        let unixServer = try PolicyFakeUnixSocketServer()
        defer { unixServer.close() }
        // No second local account exists in tests, so expect a user ID the
        // fake socket's owner cannot have. The relay connects, refuses the
        // peer and closes without writing, which is also what the stand-in
        // sees when a relay session closes in the middle of a forward.
        let server = try RemoteCLIRelayServer(
            localSocketPath: unixServer.path,
            relayID: relayID,
            relayTokenHex: tokenHex,
            commandRewriter: PolicyPassthroughRewriter(),
            localSocketPeerCheck: UnixSocketPeerCheck(expectedUserID: geteuid() &+ 1)
        )
        defer { server.stop() }
        let port = try server.start()
        let exchange = try runPolicyRelayExchange(
            port: port,
            relayID: relayID,
            tokenHex: tokenHex,
            commandLine: #"{"id":"abandoned","method":"system.ping","params":{}}"#
        )
        #expect(exchange.responseLines.first?["ok"] as? Bool == false)
        // The stand-in reads to EOF, which arrives only once the relay has
        // closed its socket, and then writes its reply into that closed socket.
        #expect(unixServer.waitForServedConnection())
        #expect(unixServer.requests == [Data()])
    }

    @Test("owned decoys cannot forward unrelated routing to the local socket", arguments: [
        "terminal_id", "preferred_workspace_id", "target_surface_id", "tab_id", "target_terminal_id"
    ])
    func deniesDecoyRoutingBeforeForwarding(key: String) throws {
        let workspace = UUID()
        let surface = UUID()
        try withServer(workspaceAliases: [workspace: workspace], surfaceAliases: [surface: surface]) { port, unixServer in
            let request: [String: Any] = [
                "id": "reporter-decoy",
                "method": "surface.send_text",
                "params": [
                    "workspace_id": workspace.uuidString,
                    "surface_id": surface.uuidString,
                    key: UUID().uuidString,
                    "text": "touch /tmp/pwned\n"
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: request)
            let exchange = try runPolicyRelayExchange(port: port, relayID: relayID,
                tokenHex: tokenHex, commandLine: String(decoding: data, as: UTF8.self))
            expectDenial(exchange, unixServer, key)
            #expect(exchange.responseLines.first?["id"] as? String == "reporter-decoy")
        }
    }

    @Test("prefix lookalikes and local-context split options are denied")
    func deniesPrefixAndLocalContext() throws {
        try withServer { port, unixServer in
            for (label, request) in [
                ("browser future method", #"{"id":"p14","method":"browser.future","params":{}}"#),
                ("group suffix", #"{"id":"p15","method":"workspace.group.delete.extra","params":{}}"#),
                ("local context", #"{"id":"p16","method":"surface.split","params":{"remote_context":"local"}}"#),
                ("initial input", #"{"id":"p17","method":"surface.split","params":{"initial_input":"touch /tmp/pwned"}}"#),
            ] {
                let exchange = try runPolicyRelayExchange(
                    port: port,
                    relayID: relayID,
                    tokenHex: tokenHex,
                    commandLine: request
                )
                expectDenial(exchange, unixServer, label)
            }
        }
    }
}
