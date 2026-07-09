import Foundation
import Testing
import CmuxAgentReplica
@testable import CmuxAgentWire

struct WireTestSupport {
    static let epoch = ReplicaEpoch(rawValue: "epoch-1")
    static let mac = MacDeviceID(rawValue: "mac-1")
    static let sessionID = AgentSessionID(rawValue: "session-1")
    static let journalID = JournalID(rawValue: "journal-1")

    static let session = AgentSessionSnapshot(
        id: sessionID,
        macDeviceID: mac,
        kind: .codex,
        phase: .needsInput,
        tier: .observed,
        surfaceID: "surface-1",
        cwd: "/repo",
        title: "Agent",
        workspaceName: "Workspace",
        version: EntityVersion(rawValue: 3),
        lastActivityHint: 7
    )

    static let entryPayload = EntryPayload.userMessage(UserMessagePayload(
        text: "Hello",
        attachmentCount: 1,
        hasImage: true
    ))

    static let entry = EntrySnapshot(
        journalID: journalID,
        seq: EntrySeq(rawValue: 10),
        kind: .userMessage,
        content: EntryContent(contentHash: 101, payload: entryPayload),
        version: EntityVersion(rawValue: 2)
    )

    static let ticket = SendTicket(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        sessionID: sessionID,
        text: "Queue this",
        attachmentCount: 2,
        state: .acceptedByMac,
        createdAt: 123
    )

    static let ask = PendingAsk(
        id: "ask-1",
        sessionID: sessionID,
        kind: .question,
        promptSummary: "Choose",
        optionsCount: 2,
        state: .answered(choice: 1)
    )

    static let sessionJSON = #"{"cwd":"\/repo","id":"session-1","kind":"codex","last_activity_hint":7,"mac_device_id":"mac-1","phase":"needsInput","surface_id":"surface-1","tier":"observed","title":"Agent","version":3,"workspace_name":"Workspace"}"#
    static let entryPayloadJSON = #"{"attachment_count":1,"has_image":true,"kind":"userMessage","text":"Hello"}"#
    static let entryJSON = #"{"content":{"content_hash":101,"payload":{"attachment_count":1,"has_image":true,"kind":"userMessage","text":"Hello"}},"journal_id":"journal-1","kind":"userMessage","seq":10,"version":2}"#
    static let ticketJSON = #"{"attachment_count":2,"created_at":123,"id":"11111111-1111-1111-1111-111111111111","session_id":"session-1","state":{"type":"acceptedByMac"},"text":"Queue this"}"#
    static let askJSON = #"{"id":"ask-1","kind":"question","options_count":2,"prompt_summary":"Choose","session_id":"session-1","state":{"choice":1,"type":"answered"}}"#

    static func assertGolden<Value: Codable & Equatable>(
        _ value: Value,
        json: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(value)
        #expect(encoded == Data(json.utf8), sourceLocation: sourceLocation)
        let decoded = try JSONDecoder().decode(Value.self, from: Data(json.utf8))
        #expect(decoded == value, sourceLocation: sourceLocation)
    }
}
