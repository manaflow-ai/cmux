import CmuxCore
import Foundation
import Testing
@testable import CmuxRemoteDaemon

@Suite("Remote runtime state wire document")
struct RemoteRuntimeStateDocumentTests {
    @Test("decodes the authoritative state and PTY manifest")
    func decodesDocument() throws {
        let decoded = try RemoteDaemonRPCClient.decodeRuntimeStateDocument([
            "present": true,
            "protocol_version": 1,
            "schema_version": 17,
            "revision": 4,
            "updated_at_unix_ms": 1_750_000_000_000 as Int64,
            "state": [
                "title": "remote workspace",
                "cwd": "/srv/project",
            ],
            "pty_sessions": [[
                "session_id": "ssh-surface-1",
                "scrollback_bytes": 2048,
            ]],
        ])
        let document = try #require(decoded)

        #expect(document.schemaVersion == 17)
        #expect(document.revision == 4)
        #expect(document.updatedAtUnixMilliseconds == 1_750_000_000_000)
        let state = try #require(JSONSerialization.jsonObject(with: document.state) as? [String: String])
        #expect(state["title"] == "remote workspace")
        #expect(state["cwd"] == "/srv/project")
        let sessions = try #require(JSONSerialization.jsonObject(with: document.ptySessions) as? [[String: Any]])
        #expect(sessions.first?["session_id"] as? String == "ssh-surface-1")
        #expect(sessions.first?["scrollback_bytes"] as? Int == 2048)
    }

    @Test("absent state decodes as nil")
    func decodesAbsentState() throws {
        let document = try RemoteDaemonRPCClient.decodeRuntimeStateDocument([
            "present": false,
            "protocol_version": 1,
            "revision": 0,
            "pty_sessions": [],
        ])
        #expect(document == nil)
    }

    @Test("rejects a malformed absent-state response")
    func rejectsMalformedAbsentState() {
        #expect(throws: (any Error).self) {
            _ = try RemoteDaemonRPCClient.decodeRuntimeStateDocument([
                "present": false,
                "revision": 0,
                "pty_sessions": [],
            ])
        }
    }

    @Test("rejects boolean values in integer fields")
    func rejectsBooleanInteger() {
        #expect(throws: (any Error).self) {
            _ = try RemoteDaemonRPCClient.decodeRuntimeStateDocument([
                "present": true,
                "protocol_version": true,
                "schema_version": 17,
                "revision": 1,
                "updated_at_unix_ms": 1,
                "state": [:],
                "pty_sessions": [],
            ])
        }
    }

    @Test("stdio framing accepts a runtime-state response near the payload limit")
    func acceptsLargeRuntimeStateFrame() throws {
        let client = Self.makeClient()
        let call = client.pendingCalls.register()
        let expectedBlob = String(repeating: "x", count: 3 * 1024 * 1024 - 1024)
        var frame = try JSONSerialization.data(withJSONObject: [
            "id": call.id,
            "ok": true,
            "result": [
                "present": true,
                "protocol_version": 1,
                "schema_version": 1,
                "revision": 1,
                "updated_at_unix_ms": 1,
                "state": ["blob": expectedBlob],
                "pty_sessions": [],
            ],
        ])
        frame.append(0x0A)

        client.stateQueue.sync {
            client.consumeStdoutData(frame)
        }

        let response: [String: Any]
        switch client.pendingCalls.wait(for: call, timeout: 0) {
        case .response(let payload):
            response = payload
        case .failure(let detail):
            Issue.record("large runtime-state frame failed: \(detail)")
            return
        case .missing:
            Issue.record("large runtime-state response was not registered")
            return
        case .timedOut:
            Issue.record("large runtime-state response timed out")
            return
        }

        let result = try #require(response["result"] as? [String: Any])
        let decoded = try RemoteDaemonRPCClient.decodeRuntimeStateDocument(result)
        let document = try #require(decoded)
        let state = try #require(JSONSerialization.jsonObject(with: document.state) as? [String: String])
        #expect(state["blob"] == expectedBlob)
    }

    @Test("rejects an unsupported protocol version")
    func rejectsUnsupportedProtocol() {
        #expect(throws: (any Error).self) {
            _ = try RemoteDaemonRPCClient.decodeRuntimeStateDocument([
                "present": true,
                "protocol_version": 2,
                "schema_version": 17,
                "revision": 1,
                "updated_at_unix_ms": 1,
                "state": [:],
                "pty_sessions": [],
            ])
        }
    }

    @Test("rejects oversized state before entering the RPC transport")
    func rejectsOversizedStateBeforeTransport() throws {
        let client = Self.makeClient()
        let state = Data(
            (#"{"blob":""# + String(repeating: "x", count: 3 * 1024 * 1024) + #""}"#).utf8
        )

        do {
            _ = try client.putRuntimeState(schemaVersion: 1, state: state)
            Issue.record("oversized runtime state unexpectedly reached the transport")
        } catch let error as NSError {
            #expect(error.domain == "cmux.remote.daemon.runtime-state")
            #expect(error.code == 46)
        }
    }

    private static func makeClient() -> RemoteDaemonRPCClient {
        RemoteDaemonRPCClient(
            configuration: WorkspaceRemoteConfiguration(
                destination: "developer@example.test",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: nil,
                relayID: nil,
                relayToken: nil,
                localSocketPath: nil,
                terminalStartupCommand: nil
            ),
            remotePath: "/usr/local/bin/cmuxd-remote",
            strings: RemoteDaemonStrings(
                missingPersistentPTYCapability: "missing persistent PTY",
                missingRequiredFunctionality: "missing required functionality"
            ),
            onUnexpectedTermination: { _ in }
        )
    }
}
