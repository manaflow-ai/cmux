import Foundation
import Testing
@testable import CmuxAgentReplica

@Suite struct EntryPayloadTests {
    @Test func allCasesRoundTripThroughTheirTaggedWireFormat() throws {
        let payloads: [EntryPayload] = [
            .userMessage(UserMessagePayload(text: "Hello", attachmentCount: 2, hasImage: true)),
            .agentProse(AgentProsePayload(markdown: "**Response**")),
            .thought(ThoughtPayload(text: "Reasoning")),
            .toolRun(ToolRunPayload(
                toolName: "Bash",
                argumentSummary: "echo test",
                resultSummary: "test",
                isTerminal: true,
                exitCode: 0,
                isRunning: false
            )),
            .fileChange(FileChangePayload(path: "/tmp/example.swift", changeKind: .edit, resultSummary: "Updated")),
            .question(QuestionPayload(prompt: "Choose", options: ["A", "B"], answeredChoice: 1)),
            .permission(PermissionPayload(toolName: "Bash", detail: "Run command", options: ["Allow", "Deny"])),
            .status(StatusPayload(code: .compacted, detail: "Context compacted")),
            .attachment(AttachmentPayload(kind: "image", summary: "Screenshot")),
            .unknown(UnknownPayload(rawKind: "future_payload", summary: "Future", rawJSON: #"{"value":1}"#)),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for payload in payloads {
            let data = try encoder.encode(payload)
            let decoded = try JSONDecoder().decode(EntryPayload.self, from: data)

            #expect(decoded == payload)
        }

        let attachmentData = try encoder.encode(payloads[8])
        #expect(String(decoding: attachmentData, as: UTF8.self) == #"{"attachment_kind":"image","kind":"attachment","summary":"Screenshot"}"#)
    }

    @Test func stableHashIsPinnedForFixedPayload() {
        let payload = EntryPayload.toolRun(ToolRunPayload(
            toolName: "Bash",
            argumentSummary: "echo pinned",
            resultSummary: "pinned",
            isTerminal: true,
            exitCode: 0,
            isRunning: false
        ))

        #expect(payload.stableHash == 218_440_145_013_379_715)
    }

    @Test func contentDecodesOldLogsWithMissingPayloadAsUnknown() throws {
        let data = Data(#"{"contentHash":42}"#.utf8)
        let decoded = try JSONDecoder().decode(EntryContent.self, from: data)

        #expect(decoded.contentHash == 42)
        #expect(decoded.payload == .unknown(UnknownPayload(rawKind: "unknown")))
    }

    @Test func knownPayloadDecodeFailureFallsBackToUnknownWithBoundedRawJSON() throws {
        let data = Data(#"{"kind":"toolRun","tool_name":12,"argument_summary":false,"extra":"value"}"#.utf8)
        let decoded = try JSONDecoder().decode(EntryPayload.self, from: data)

        guard case .unknown(let payload) = decoded else {
            Issue.record("Expected unknown payload")
            return
        }
        #expect(payload.rawKind == "toolRun")
        #expect(payload.rawJSON?.contains(#""tool_name":12"#) == true)
        #expect(!payload.rawJSONTruncated)
    }

    @Test func unknownSentinelRoundTripsWithoutRawJSONDrift() throws {
        let payload = EntryPayload.unknown(UnknownPayload(
            rawKind: "unknown",
            summary: "Unclassified",
            rawJSON: #"{"source":"fixture"}"#
        ))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let firstEncoding = try encoder.encode(payload)
        let firstDecode = try JSONDecoder().decode(EntryPayload.self, from: firstEncoding)
        let secondEncoding = try encoder.encode(firstDecode)
        let secondDecode = try JSONDecoder().decode(EntryPayload.self, from: secondEncoding)

        #expect(firstDecode == payload)
        #expect(secondDecode == payload)
        #expect(secondEncoding == firstEncoding)
        #expect(secondDecode.stableHash == payload.stableHash)
    }

    @Test func nonObjectPayloadDecodesDirectlyAsUnknown() throws {
        let data = Data(#""unstructured payload""#.utf8)
        let decoded = try JSONDecoder().decode(EntryPayload.self, from: data)

        #expect(decoded == .unknown(UnknownPayload(
            rawKind: "unknown",
            rawJSON: #""unstructured payload""#
        )))
    }

    @Test func unknownPayloadRawJSONIsCappedAtEightKilobytes() {
        let raw = String(repeating: "x", count: UnknownPayload.rawJSONByteLimit + 32)
        let payload = UnknownPayload(rawKind: "future", rawJSON: raw)

        #expect(payload.rawJSON?.utf8.count == UnknownPayload.rawJSONByteLimit)
        #expect(payload.rawJSONTruncated)
    }
}
