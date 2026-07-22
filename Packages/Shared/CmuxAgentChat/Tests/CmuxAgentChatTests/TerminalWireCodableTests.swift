import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("Terminal wire codable")
struct TerminalWireCodableTests {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Test("TerminalCommandBlock round-trips through JSON with snake_case keys")
    func blockRoundTrip() throws {
        let block = TerminalCommandBlock(
            id: 3, command: "npm test", output: "ok\n",
            exitCode: 1, isRunning: false, isInteractive: true
        )
        let data = try encoder.encode(block)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"exit_code\""))
        #expect(json.contains("\"is_running\""))
        #expect(json.contains("\"is_interactive\""))
        #expect(try decoder.decode(TerminalCommandBlock.self, from: data) == block)
    }

    @Test("a running block (nil exit) round-trips")
    func runningBlockRoundTrip() throws {
        let block = TerminalCommandBlock(id: 0, command: "tail -f", output: "...", exitCode: nil, isRunning: true)
        let data = try encoder.encode(block)
        #expect(try decoder.decode(TerminalCommandBlock.self, from: data) == block)
    }

    @Test("ChatSessionEvent.terminalBlocks round-trips")
    func eventRoundTrip() throws {
        let event = ChatSessionEvent.terminalBlocks([
            TerminalCommandBlock(id: 0, command: "ls", output: "a\n", exitCode: 0, isRunning: false),
            TerminalCommandBlock(id: 1, command: "pwd", output: "/tmp\n", exitCode: 0, isRunning: false),
        ])
        let data = try encoder.encode(event)
        #expect(String(decoding: data, as: UTF8.self).contains("\"terminal_blocks\""))
        #expect(try decoder.decode(ChatSessionEvent.self, from: data) == event)
    }

    @Test("ChatSessionEvent.sessionRemoved round-trips")
    func sessionRemovedEventRoundTrip() throws {
        let event = ChatSessionEvent.sessionRemoved(version: 9)
        let data = try encoder.encode(event)
        #expect(String(decoding: data, as: UTF8.self).contains("\"session_removed\""))
        #expect(String(decoding: data, as: UTF8.self).contains("\"version\":9"))
        #expect(try decoder.decode(ChatSessionEvent.self, from: data) == event)
    }

    @Test("ChatSessionEvent.sessionRemoved decodes missing version compatibly")
    func sessionRemovedMissingVersionDecodesAsUnversioned() throws {
        let data = #"{"event":"session_removed"}"#.data(using: .utf8)!
        #expect(try decoder.decode(ChatSessionEvent.self, from: data) == .sessionRemoved(version: Int.max))
    }

    @Test("ChatHistoryPage carries terminal blocks and stays backward-compatible")
    func historyPageTerminal() throws {
        let page = ChatHistoryPage(
            messages: [], hasMore: false,
            terminalBlocks: [TerminalCommandBlock(id: 0, command: "echo hi", output: "hi\n", exitCode: 0, isRunning: false)]
        )
        let data = try encoder.encode(page)
        #expect(try decoder.decode(ChatHistoryPage.self, from: data) == page)
        // An agent-era payload without the terminal_blocks key still decodes.
        let agentJSON = #"{"messages":[],"has_more":true}"#.data(using: .utf8)!
        let decoded = try decoder.decode(ChatHistoryPage.self, from: agentJSON)
        #expect(decoded.terminalBlocks == nil)
        #expect(decoded.hasMore == true)
    }

    @Test("ChatSessionDescriptor.kind travels on the wire and defaults to agent when absent")
    func descriptorKindRoundTrip() throws {
        let terminal = ChatSessionDescriptor(
            id: "surface-1", agentKind: .other("terminal"), kind: .terminal,
            workspaceID: "ws-1", terminalID: "surface-1"
        )
        let data = try encoder.encode(terminal)
        #expect(String(decoding: data, as: UTF8.self).contains("\"kind\""))
        #expect(try decoder.decode(ChatSessionDescriptor.self, from: data).kind == .terminal)
        // A payload missing "kind" (older producer) decodes as .agent. Derive
        // it by stripping the key from a real encoding (avoids hardcoding the
        // nested state shape).
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "kind")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        #expect(try decoder.decode(ChatSessionDescriptor.self, from: legacy).kind == .agent)
    }

    @Test("Terminal artifact scan metadata round-trips with unix modified time")
    func terminalArtifactScanMetadataRoundTrip() throws {
        let modifiedAt = Date(timeIntervalSince1970: 1_649_116_800.25)
        let response = TerminalArtifactScanResponse(artifacts: [
            TerminalArtifactReference(
                path: "/tmp/report.txt",
                kind: .text,
                displayName: "report.txt",
                size: 3_072,
                modifiedAt: modifiedAt
            ),
        ], sessionID: "session-1", sessionArtifactTotal: 12)
        let coding = ChatWireCoding()
        let data = try coding.encode(response)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let artifacts = try #require(object["artifacts"] as? [[String: Any]])
        let artifact = try #require(artifacts.first)

        #expect((artifact["size"] as? NSNumber)?.int64Value == 3_072)
        #expect((artifact["modified_at"] as? NSNumber)?.doubleValue == modifiedAt.timeIntervalSince1970)
        #expect(object["session_id"] as? String == "session-1")
        #expect(object["session_artifact_total"] as? Int == 12)
        #expect(try coding.decode(TerminalArtifactScanResponse.self, from: data) == response)
    }

    @Test("Terminal artifact scan decodes legacy references without metadata")
    func terminalArtifactScanLegacyMetadata() throws {
        let data = #"{"artifacts":[{"path":"/tmp/report.txt","kind":"text","display_name":"report.txt"}]}"#
            .data(using: .utf8)!
        let reference = try #require(
            ChatWireCoding().decode(TerminalArtifactScanResponse.self, from: data).artifacts.first
        )

        #expect(reference.size == nil)
        #expect(reference.modifiedAt == nil)
    }

    @Test("Terminal artifact scan ignores unknown fields and defaults new totals absent")
    func terminalArtifactScanVersionSkew() throws {
        let legacy = Data(#"{"artifacts":[],"session_id":"session-1"}"#.utf8)
        let legacyResponse = try ChatWireCoding().decode(TerminalArtifactScanResponse.self, from: legacy)
        #expect(legacyResponse.sessionArtifactTotal == nil)

        let newer = Data(
            #"{"artifacts":[],"session_id":"session-1","session_artifact_total":9,"future_field":true}"#.utf8
        )
        let newerResponse = try ChatWireCoding().decode(TerminalArtifactScanResponse.self, from: newer)
        #expect(newerResponse.sessionArtifactTotal == 9)
    }

    @Test("terminal directory listing round-trips cap metadata and decodes legacy payloads")
    func terminalDirectoryListingRoundTrip() throws {
        let listing = ChatArtifactDirectoryListing(
            entries: [
                ChatArtifactDirectoryEntry(name: "Sources", isDirectory: true, size: 0, kind: .directory),
                ChatArtifactDirectoryEntry(name: "README.md", isDirectory: false, size: 42, kind: .text),
            ],
            isTruncated: true
        )
        let coding = ChatWireCoding()
        let data = try coding.encode(listing)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["is_truncated"] as? Bool == true)
        #expect(try coding.decode(ChatArtifactDirectoryListing.self, from: data) == listing)

        let legacy = Data(#"{"entries":[]}"#.utf8)
        #expect(try coding.decode(ChatArtifactDirectoryListing.self, from: legacy).isTruncated == false)
    }
}
