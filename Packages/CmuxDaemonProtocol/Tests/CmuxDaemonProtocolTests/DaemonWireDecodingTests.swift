import Foundation
import Testing

@testable import CmuxDaemonProtocol

@Suite("Daemon wire decoding")
struct DaemonWireDecodingTests {
    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    @Test("Hello decodes snake_case wire keys")
    func helloDecodes() throws {
        let json = """
        {
          "name": "cmuxd-remote",
          "version": "1.2.3",
          "instance_id": "abc-123",
          "workspace_count": 4,
          "change_seq": 99,
          "capabilities": ["workspace.list", "session.attach"]
        }
        """
        let hello = try makeDecoder().decode(
            TerminalRemoteDaemonHello.self,
            from: Data(json.utf8)
        )
        #expect(hello.name == "cmuxd-remote")
        #expect(hello.version == "1.2.3")
        #expect(hello.instanceID == "abc-123")
        #expect(hello.workspaceCount == 4)
        #expect(hello.changeSeq == 99)
        #expect(hello.capabilities == ["workspace.list", "session.attach"])
    }

    @Test("Hello tolerates omitted optional fields")
    func helloOptionalFields() throws {
        let json = """
        { "name": "d", "version": "0", "instance_id": null, "capabilities": [] }
        """
        let hello = try makeDecoder().decode(
            TerminalRemoteDaemonHello.self,
            from: Data(json.utf8)
        )
        #expect(hello.instanceID == nil)
        #expect(hello.workspaceCount == nil)
        #expect(hello.changeSeq == nil)
        #expect(hello.capabilities.isEmpty)
    }

    @Test("TerminalReadResult decodes base64 data and snake_case keys")
    func readResultDecodes() throws {
        let payload = Data([0x68, 0x69, 0x21]) // "hi!"
        let json = """
        {
          "session_id": "s1",
          "offset": 128,
          "base_offset": 64,
          "truncated": true,
          "eof": false,
          "data": "\(payload.base64EncodedString())"
        }
        """
        let result = try makeDecoder().decode(
            TerminalRemoteDaemonTerminalReadResult.self,
            from: Data(json.utf8)
        )
        #expect(result.sessionID == "s1")
        #expect(result.offset == 128)
        #expect(result.baseOffset == 64)
        #expect(result.truncated == true)
        #expect(result.eof == false)
        #expect(result.data == payload)
    }

    @Test("TerminalReadResult rejects non-base64 data")
    func readResultRejectsBadBase64() {
        let json = """
        {
          "session_id": "s1",
          "offset": 0,
          "base_offset": 0,
          "truncated": false,
          "eof": false,
          "data": "not valid base64 !!!"
        }
        """
        #expect(throws: DecodingError.self) {
            _ = try makeDecoder().decode(
                TerminalRemoteDaemonTerminalReadResult.self,
                from: Data(json.utf8)
            )
        }
    }

    @Test("WorkspaceListResult decodes nested entries and panes")
    func workspaceListDecodes() throws {
        let json = """
        {
          "workspaces": [
            {
              "id": "w1",
              "title": "Repo",
              "directory": "/tmp/repo",
              "focused_pane_id": "p1",
              "pane_count": 2,
              "created_at": 1000,
              "last_activity_at": 2000,
              "session_id": "s1",
              "preview": "$ ls",
              "unread_count": 3,
              "pinned": true,
              "panes": [
                { "id": "p1", "session_id": "s1", "title": "shell", "directory": "/tmp/repo" }
              ]
            }
          ],
          "selected_workspace_id": "w1",
          "change_seq": 7
        }
        """
        let result = try makeDecoder().decode(
            TerminalRemoteDaemonWorkspaceListResult.self,
            from: Data(json.utf8)
        )
        #expect(result.selectedWorkspaceID == "w1")
        #expect(result.changeSeq == 7)
        let entry = try #require(result.workspaces.first)
        #expect(entry.id == "w1")
        #expect(entry.focusedPaneID == "p1")
        #expect(entry.paneCount == 2)
        #expect(entry.createdAt == 1000)
        #expect(entry.lastActivityAt == 2000)
        #expect(entry.unreadCount == 3)
        #expect(entry.pinned == true)
        let pane = try #require(entry.panes?.first)
        #expect(pane.id == "p1")
        #expect(pane.sessionID == "s1")
    }

    @Test("DaemonTicketRequest encodes snake_case keys and sorts capabilities")
    func ticketRequestEncodes() throws {
        let request = TerminalDaemonTicketRequest(
            serverID: "srv",
            teamID: "team",
            sessionID: "sess",
            attachmentID: "att",
            capabilities: ["session.resize", "session.attach"]
        )
        // Capabilities are sorted on init for stable identity.
        #expect(request.capabilities == ["session.attach", "session.resize"])

        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["server_id"] as? String == "srv")
        #expect(object["team_id"] as? String == "team")
        #expect(object["session_id"] as? String == "sess")
        #expect(object["attachment_id"] as? String == "att")
        #expect(object["capabilities"] as? [String] == ["session.attach", "session.resize"])
    }

    @Test("DaemonTicket decodes and normalizes direct-TLS pins")
    func ticketDecodesAndNormalizesPins() throws {
        let expiry = "2030-01-02T03:04:05Z"
        let json = """
        {
          "ticket": "tok",
          "direct_url": "https://10.0.0.1:8443",
          "direct_tls_pins": [" pinA ", "pinA", "", "pinB"],
          "session_id": "s1",
          "attachment_id": "a1",
          "expires_at": "\(expiry)"
        }
        """
        let ticket = try makeDecoder().decode(
            TerminalDaemonTicket.self,
            from: Data(json.utf8)
        )
        #expect(ticket.ticket == "tok")
        #expect(ticket.directURL == URL(string: "https://10.0.0.1:8443"))
        #expect(ticket.sessionID == "s1")
        #expect(ticket.attachmentID == "a1")
        // Trimmed, de-duplicated, empties removed.
        #expect(ticket.directTLSPins == ["pinA", "pinB"])
    }

    @Test("RPC method constants match the wire strings")
    func rpcMethodConstants() {
        #expect(DaemonRPCMethod.hello == "hello")
        #expect(DaemonRPCMethod.sessionOpen == "session.open")
        #expect(DaemonRPCMethod.workspaceOpenPane == "workspace.open_pane")
        #expect(DaemonRPCMethod.daemonConfigureNotifications == "daemon.configure_notifications")
    }
}
