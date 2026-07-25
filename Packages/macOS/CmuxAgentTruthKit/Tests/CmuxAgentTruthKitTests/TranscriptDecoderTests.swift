import CmuxAgentReplica
import Foundation
@testable import CmuxAgentTruthKit
import Testing

@Suite
struct TranscriptDecoderTests {
    private static let png1x1Base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
    private static let png1x1Data = Data(base64Encoded: png1x1Base64)!

    @Test
    func claudeGoldenFixture() throws {
        let lines = try fixtureLines("claude-synthetic")
        var decoder = ClaudeTranscriptDecoder()
        let batch = decoder.feed(lines, startingAt: 0, journalID: JournalID(rawValue: "claude-journal"))

        #expect(kindTable(batch.entries) == [
            "0:fixture_comment",
            "1:userMessage",
            "2:agentProse",
            "3:thought",
            "4:toolRun",
            "5:toolRun",
            "6:fileChange",
            "7:question",
            "10:agentProse",
            "11:toolRun",
            "11:status",
            "12:status",
            "14:userMessage",
            "15:attachment",
            "25:attachment",
            "26:future_block",
            "27:malformed",
            "28:future_record",
        ])
        #expect(batch.diagnostics.unknownKindCounts["malformed"] == 1)
        #expect(batch.diagnostics.unknownKindCounts["future_block"] == 1)
        #expect(batch.diagnostics.modeledKindCounts["sidechain"] == 1)
        #expect(batch.diagnostics.modeledKindCounts["meta"] == 1)
        #expect(batch.diagnostics.modeledKindCounts["system.api_error"] == 1)
        #expect(batch.diagnostics.modeledKindCounts["system.stop_hook_summary"] == 1)
        #expect(batch.diagnostics.modeledKindCounts["system.turn_duration"] == 1)
        #expect(batch.diagnostics.bookkeepingKindCounts["ai-title"] == 1)
        #expect(batch.diagnostics.bookkeepingKindCounts["attachment"] == 1)
        #expect(batch.diagnostics.sawApiError)
        #expect(batch.diagnostics.sensitiveSessionTitles.map(\.source) == ["ai-title", "custom-title", "agent-name"])
        #expect(userMessagePayload(in: batch, seq: 14)?.hasImage == false)
        #expect(attachmentPayload(in: batch, seq: 15)?.mimeType == "image/png")
        #expect(toolRunPayload(in: batch, seq: 5)?.exitCode == 0)
        #expect(toolRunPayload(in: batch, seq: 5)?.toolCallID == "toolu_001")
        #expect(toolRunPayload(in: batch, seq: 5)?.command == "echo example")
        #expect(toolRunPayload(in: batch, seq: 5)?.output == "example output")
        #expect(fileChangePayload(in: batch, seq: 6)?.path == "/tmp/example/file.txt")
        #expect(fileChangePayload(in: batch, seq: 6)?.toolCallID == "toolu_002")
        #expect(fileChangePayload(in: batch, seq: 6)?.unifiedDiff?.contains("--- before") == true)
        #expect(attachmentPayload(in: batch, seq: 25)?.displayName == "example.png")
        #expect(questionPayload(in: batch, seq: 7)?.options == ["Alpha", "Beta"])
        #expect(batch.entries.contains { entry in
            if case .status(let status) = entry.content.payload { return status.code == .apiError }
            return false
        })
        #expect(unknownPayload(in: batch, seq: 26)?.rawKind == "future_block")
    }

    @Test
    func codexGoldenFixture() throws {
        let lines = try fixtureLines("codex-synthetic")
        var decoder = CodexTranscriptDecoder()
        let batch = decoder.feed(lines, startingAt: 0, journalID: JournalID(rawValue: "codex-journal"))

        #expect(kindTable(batch.entries) == [
            "0:fixture_comment",
            "1:status",
            "2:userMessage",
            "3:agentProse",
            "4:thought",
            "5:toolRun",
            "6:toolRun",
            "7:fileChange",
            "8:fileChange",
            "9:toolRun",
            "10:toolRun",
            "11:toolRun",
            "15:status",
            "16:status",
            "27:malformed",
            "28:future_item",
        ])
        #expect(batch.diagnostics.unknownKindCounts["malformed"] == 1)
        #expect(batch.diagnostics.unknownKindCounts["future_item"] == 1)
        #expect(batch.diagnostics.modeledKindCounts["event_msg.task_started"] == 1)
        #expect(batch.diagnostics.modeledKindCounts["event_msg.task_complete"] == 1)
        #expect(batch.diagnostics.modeledKindCounts["event_msg.context_compacted"] == 1)
        #expect(batch.diagnostics.duplicateStreamCounts["event_msg.user_message"] == 1)
        #expect(batch.diagnostics.duplicateStreamCounts["event_msg.agent_message"] == 1)
        #expect(batch.diagnostics.phaseFacts == [.taskStarted(line: 13), .taskCompleted(line: 14), .turnAborted(line: 15)])
        #expect(batch.diagnostics.turnContextFacts == [TurnContextFact(line: 12, model: "gpt-5.5", sandboxPolicy: "danger-full-access", approvalPolicy: "never")])
        #expect(batch.diagnostics.cliVersion == "0.140.0")
        #expect(toolRunPayload(in: batch, seq: 5)?.argumentSummary.contains("echo example") == true)
        #expect(toolRunPayload(in: batch, seq: 5)?.toolCallID == "call_001")
        #expect(toolRunPayload(in: batch, seq: 5)?.command == "echo example")
        #expect(toolRunPayload(in: batch, seq: 6)?.output == "example output")
        #expect(batch.entries.first { $0.seq.rawValue == 2 }?.timestampMilliseconds != nil)
        #expect(fileChangePayload(in: batch, seq: 8)?.resultSummary?.contains("patch applied") == true)
        #expect(statusPayload(in: batch, seq: 15)?.code == .turnAborted)
    }

    @Test
    func codexUserImageEmitsStructuredAttachmentWithLocalPath() throws {
        let line = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Inspect this image.\n<image name=[Image #1] path=\"/tmp/codex-inline-test.png\">"},{"type":"input_image","image_url":"data:image/png;base64,\#(Self.png1x1Base64)"}]}}"#
        var decoder = CodexTranscriptDecoder()
        let batch = decoder.feed([line], startingAt: 0, journalID: JournalID(rawValue: "journal"))

        #expect(kindTable(batch.entries) == ["0:userMessage", "1:attachment"])
        #expect(userMessagePayload(in: batch, seq: 0)?.attachmentCount == 1)
        #expect(userMessagePayload(in: batch, seq: 0)?.hasImage == true)
        let attachment = try #require(attachmentPayload(in: batch, seq: 1))
        #expect(attachment.kind == "image")
        #expect(attachment.displayName == "codex-inline-test.png")
        #expect(attachment.hostPath == "/tmp/codex-inline-test.png")
        #expect(attachment.mimeType == "image/png")
        #expect(attachment.width == 1)
        #expect(attachment.height == 1)
        #expect(attachment.byteCount == Self.png1x1Data.count)
    }

    @Test
    func codexCustomToolOutputPairsByCallID() {
        let lines = [
            #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","call_id":"call_patch","input":"patch placeholder"}}"#,
            #"{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call_patch","output":"patch complete"}}"#,
        ]
        var decoder = CodexTranscriptDecoder()
        let batch = decoder.feed(lines, startingAt: 0, journalID: JournalID(rawValue: "journal"))

        #expect(kindTable(batch.entries) == ["0:fileChange", "1:fileChange"])
        #expect(fileChangePayload(in: batch, seq: 1)?.resultSummary?.contains("patch complete") == true)
        #expect(batch.diagnostics.unknownKindCounts.isEmpty)
    }

    @Test
    func codexToolSearchOutputPairsByCallID() {
        let lines = [
            #"{"type":"response_item","payload":{"type":"tool_search_call","call_id":"call_search","arguments":{"query":"example"}}}"#,
            #"{"type":"response_item","payload":{"type":"tool_search_output","call_id":"call_search","status":"completed","tools":[{"name":"example_tool"}]}}"#,
        ]
        var decoder = CodexTranscriptDecoder()
        let batch = decoder.feed(lines, startingAt: 0, journalID: JournalID(rawValue: "journal"))

        #expect(kindTable(batch.entries) == ["0:toolRun", "1:toolRun"])
        #expect(toolRunPayload(in: batch, seq: 1)?.toolName == "tool_search")
        #expect(batch.diagnostics.unknownKindCounts.isEmpty)
    }

    @Test
    func codexUnpairedOutputsRemainVisibleAsCompletedToolRows() {
        let lines = [
            #"{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"missing_patch","output":"patch complete"}}"#,
            #"{"type":"response_item","payload":{"type":"tool_search_output","call_id":"missing_search","status":"completed","tools":[]}}"#,
        ]
        var decoder = CodexTranscriptDecoder()
        let batch = decoder.feed(lines, startingAt: 0, journalID: JournalID(rawValue: "journal"))

        #expect(kindTable(batch.entries) == ["0:toolRun", "1:toolRun"])
        #expect(toolRunPayload(in: batch, seq: 0)?.toolCallID == "missing_patch")
        #expect(toolRunPayload(in: batch, seq: 0)?.output == "patch complete")
        #expect(toolRunPayload(in: batch, seq: 0)?.status == "unpaired_result:completed")
        #expect(toolRunPayload(in: batch, seq: 1)?.toolCallID == "missing_search")
        #expect(batch.diagnostics.unknownKindCounts["custom_tool_call_output"] == 1)
        #expect(batch.diagnostics.unknownKindCounts["tool_search_output"] == 1)
        #expect(batch.diagnostics.unknownKindCounts["function_call_output"] == nil)
    }

    @Test
    func claudeUnpairedToolResultRemainsVisibleAsCompletedToolRow() {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"missing_tool","content":"visible output","is_error":true}]}}"#,
        ]
        var decoder = ClaudeTranscriptDecoder()
        let batch = decoder.feed(lines, startingAt: 0, journalID: JournalID(rawValue: "journal"))

        #expect(kindTable(batch.entries) == ["0:toolRun"])
        #expect(toolRunPayload(in: batch, seq: 0)?.toolCallID == "missing_tool")
        #expect(toolRunPayload(in: batch, seq: 0)?.output == "visible output")
        #expect(toolRunPayload(in: batch, seq: 0)?.status == "unpaired_result:failed")
        #expect(batch.diagnostics.unknownKindCounts["tool_result"] == 1)
    }

    @Test
    func codexPhaseFactsAndEventCompactionStatus() {
        let lines = [
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn_example"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn_example"}}"#,
            #"{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn_example"}}"#,
            #"{"type":"event_msg","payload":{"type":"context_compacted"}}"#,
        ]
        var decoder = CodexTranscriptDecoder()
        let batch = decoder.feed(lines, startingAt: 40, journalID: JournalID(rawValue: "journal"))

        #expect(kindTable(batch.entries) == ["42:status", "43:status"])
        #expect(batch.diagnostics.phaseFacts == [.taskStarted(line: 40), .taskCompleted(line: 41), .turnAborted(line: 42)])
    }

    @Test
    func codexOutOfRangeExitCodeFailsOpen() {
        let lines = [
            #"{"type":"response_item","payload":{"type":"function_call","name":"shell","call_id":"call_huge","arguments":{"command":["bash","-lc","echo done"]}}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call_huge","output":"done","exit_code":1e300}}"#,
        ]
        var decoder = CodexTranscriptDecoder()
        let batch = decoder.feed(lines, startingAt: 0, journalID: JournalID(rawValue: "journal"))

        #expect(toolRunPayload(in: batch, seq: 1)?.exitCode == nil)
        #expect(toolRunPayload(in: batch, seq: 1)?.isRunning == false)
    }

    @Test
    func codexTerminalClassificationUsesNameAndParsedCommandArray() {
        let lines = [
            #"{"type":"response_item","payload":{"type":"function_call","name":"search_docs","arguments":"{\"query\":\"bash reference\"}"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"custom_runner","arguments":"{\"command\":[\"bash\",\"-lc\",\"echo done\"]}"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"query\":\"reference\"}"}}"#,
        ]
        var decoder = CodexTranscriptDecoder()
        let batch = decoder.feed(lines, startingAt: 0, journalID: JournalID(rawValue: "journal"))

        #expect(toolRunPayload(in: batch, seq: 0)?.isTerminal == false)
        #expect(toolRunPayload(in: batch, seq: 1)?.isTerminal == true)
        #expect(toolRunPayload(in: batch, seq: 2)?.isTerminal == true)
    }

    @Test
    func codexRequestUserInputPreservesPromptAndOptionLabels() {
        let arguments = #"{"questions":[{"header":"Color","id":"color","question":"Pick a color family.","options":[{"label":"Warm","description":"Reds and oranges."},{"label":"Cool","description":"Blues and greens."}]}]}"#
        let lines = [
            #"{"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"call_question","arguments":"\#(arguments.replacingOccurrences(of: "\"", with: "\\\""))"}}"#,
        ]
        var decoder = CodexTranscriptDecoder()
        let batch = decoder.feed(lines, startingAt: 0, journalID: JournalID(rawValue: "journal"))

        #expect(questionPayload(in: batch, seq: 0)?.prompt == "Pick a color family.")
        #expect(questionPayload(in: batch, seq: 0)?.options == ["Warm", "Cool"])
    }

    @Test
    func codexToolOutputIsBoundedBeforeEnteringTheReplica() {
        let oversized = String(repeating: "x", count: 32_000)
        let lines = [
            #"{"type":"response_item","payload":{"type":"function_call","name":"shell","call_id":"call_large","arguments":{"command":["bash","-lc","echo done"]}}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call_large","output":"\#(oversized)"}}"#,
        ]
        var decoder = CodexTranscriptDecoder()
        let batch = decoder.feed(lines, startingAt: 0, journalID: JournalID(rawValue: "journal"))

        #expect((toolRunPayload(in: batch, seq: 1)?.resultSummary?.utf8.count ?? .max) <= 16_384)
    }

    @Test
    func claudeNonShellToolResultSynthesizesZeroExitCode() {
        let lines = [
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tool_non_shell","name":"WebSearch","input":{"query":"example"}}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool_non_shell","content":"result","is_error":false}]}}"#,
        ]
        var decoder = ClaudeTranscriptDecoder()
        let batch = decoder.feed(lines, startingAt: 0, journalID: JournalID(rawValue: "journal"))

        #expect(toolRunPayload(in: batch, seq: 1)?.isTerminal == false)
        #expect(toolRunPayload(in: batch, seq: 1)?.exitCode == 0)
    }

    @Test
    func claudeImageBlockPreservesTextAndStructuredAttachment() throws {
        let plain = [
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Same prompt."}]}}"#,
        ]
        let withImage = [
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Same prompt."},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"<redacted-image-data>"}}]}}"#,
        ]
        var plainDecoder = ClaudeTranscriptDecoder()
        var imageDecoder = ClaudeTranscriptDecoder()
        let plainEntry = try #require(plainDecoder.feed(plain, startingAt: 0, journalID: JournalID(rawValue: "journal")).entries.first)
        let imageBatch = imageDecoder.feed(withImage, startingAt: 0, journalID: JournalID(rawValue: "journal"))
        let imageEntry = try #require(imageBatch.entries.first)

        #expect(plainEntry.kind == .userMessage)
        #expect(imageEntry.kind == .userMessage)
        #expect(plainEntry.content == imageEntry.content)
        #expect(imageBatch.entries.count == 2)
        #expect(userMessagePayload(in: imageBatch, seq: 0)?.hasImage == false)
        #expect(attachmentPayload(in: imageBatch, seq: 1)?.mimeType == "image/png")
    }

    @Test
    func claudeBase64ImagePublishesDeferredImageSideTable() throws {
        let encodedImage = Self.png1x1Base64
        var decoder = ClaudeTranscriptDecoder()
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Inspect this image."},{"type":"image","file_name":"claude-inline-test.png","source":{"type":"base64","media_type":"image/png","data":"\#(encodedImage)"}}]}}"#
        let journalID = JournalID(rawValue: "journal")
        let batch = decoder.feed([line], startingAt: 0, journalID: journalID)

        #expect(kindTable(batch.entries) == ["0:userMessage", "1:attachment"])
        let attachment = try #require(attachmentPayload(in: batch, seq: 1))
        #expect(attachment.hostPath == nil)
        #expect(attachment.mimeType == "image/png")
        #expect(attachment.byteCount == Self.png1x1Data.count)
        #expect(attachment.width == 1)
        #expect(attachment.height == 1)
        let embedded = try #require(batch.embeddedImages.first)
        #expect(batch.embeddedImages.count == 1)
        #expect(embedded.journalID == journalID)
        #expect(embedded.entrySeq == EntrySeq(rawValue: 1))
        #expect(embedded.mimeType == "image/png")
        #expect(embedded.base64EncodedData == encodedImage)
        #expect(!String(decoding: try JSONEncoder().encode(batch.entries), as: UTF8.self).contains(encodedImage))
    }

    @Test
    func codexImageWithoutLocalPathPublishesDeferredImageSideTable() throws {
        let encodedImage = Self.png1x1Base64
        let line = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Inspect this image."},{"type":"input_image","image_url":"data:image/png;base64,\#(encodedImage)"}]}}"#
        let journalID = JournalID(rawValue: "codex-journal")
        var decoder = CodexTranscriptDecoder()
        let batch = decoder.feed([line], startingAt: 40, journalID: journalID)

        #expect(kindTable(batch.entries) == ["40:userMessage", "41:attachment"])
        let attachment = try #require(attachmentPayload(in: batch, seq: 41))
        #expect(attachment.hostPath == nil)
        #expect(attachment.mimeType == "image/png")
        #expect(attachment.width == 1)
        #expect(attachment.height == 1)
        #expect(attachment.byteCount == Self.png1x1Data.count)
        let embedded = try #require(batch.embeddedImages.first)
        #expect(batch.embeddedImages.count == 1)
        #expect(embedded.journalID == journalID)
        #expect(embedded.entrySeq == EntrySeq(rawValue: 41))
        #expect(embedded.mimeType == "image/png")
        #expect(embedded.base64EncodedData == encodedImage)
    }

    @Test
    func codexRatioOnlyImageMetadataSurvivesDecoding() throws {
        let line = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Preview this artifact."},{"type":"input_image","name":"artifact-preview","aspect_ratio":0.5625}]}}"#
        var decoder = CodexTranscriptDecoder()
        let batch = decoder.feed([line], startingAt: 0, journalID: JournalID(rawValue: "journal"))

        #expect(kindTable(batch.entries) == ["0:userMessage", "1:attachment"])
        let attachment = try #require(attachmentPayload(in: batch, seq: 1))
        #expect(attachment.kind == "image")
        #expect(attachment.displayName == "artifact-preview")
        #expect(attachment.width == nil)
        #expect(attachment.height == nil)
        #expect(attachment.aspectRatio == 0.5625)
    }

    @Test
    func codexPathOnlyImageDerivesDimensionsFromFileHeader() throws {
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-path-only-\(UUID().uuidString).png")
        try Self.png1x1Data.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let line = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Inspect.\n<image name=[Image #1] path=\"\#(imageURL.path)\">"}]}}"#
        var decoder = CodexTranscriptDecoder()
        let batch = decoder.feed([line], startingAt: 0, journalID: JournalID(rawValue: "journal"))

        #expect(kindTable(batch.entries) == ["0:userMessage", "1:attachment"])
        let attachment = try #require(attachmentPayload(in: batch, seq: 1))
        #expect(attachment.hostPath == imageURL.path)
        #expect(attachment.width == 1)
        #expect(attachment.height == 1)
        #expect(attachment.byteCount == Self.png1x1Data.count)
    }

    @Test
    func codexAssistantMarkdownImageEmitsPreviewMetadataInSourceOrder() throws {
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-markdown-\(UUID().uuidString).png")
        try Self.png1x1Data.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let line = #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Before\n\n![Codex Preview](\#(imageURL.path))\n\nAfter"}]}}"#
        var decoder = CodexTranscriptDecoder()
        let batch = decoder.feed([line], startingAt: 0, journalID: JournalID(rawValue: "journal"))

        #expect(kindTable(batch.entries) == ["0:agentProse", "1:attachment", "2:agentProse"])
        let attachment = try #require(attachmentPayload(in: batch, seq: 1))
        #expect(attachment.hostPath == imageURL.path)
        #expect(attachment.displayName == "Codex Preview")
        #expect(attachment.mimeType == "image/png")
        #expect(attachment.width == 1)
        #expect(attachment.height == 1)
        #expect(attachment.byteCount == Self.png1x1Data.count)
        #expect(attachment.authorRole == "agent")
    }

    @Test
    func codexAssistantMarkdownImageRatioMetadataSurvivesWithoutImageFile() throws {
        let line = #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"![Codex Preview](/tmp/codex-preview.png?aspect_ratio=1.333333)"}]}}"#
        var decoder = CodexTranscriptDecoder()
        let batch = decoder.feed([line], startingAt: 0, journalID: JournalID(rawValue: "journal"))

        #expect(kindTable(batch.entries) == ["0:attachment"])
        let attachment = try #require(attachmentPayload(in: batch, seq: 0))
        #expect(attachment.hostPath == "/tmp/codex-preview.png")
        #expect(attachment.width == nil)
        #expect(attachment.height == nil)
        #expect(attachment.aspectRatio == 1.333333)
    }

    @Test
    func codexViewImageToolCarriesPreviewMetadataThroughCompletion() throws {
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-view-image-\(UUID().uuidString).png")
        try Self.png1x1Data.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let callLine = #"{"type":"response_item","payload":{"type":"function_call","name":"view_image","call_id":"call_image","arguments":"{\"path\":\"\#(imageURL.path)\"}"}}"#
        let resultLine = #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call_image","output":"loaded preview"}}"#
        var decoder = CodexTranscriptDecoder()

        let call = decoder.feed([callLine], startingAt: 0, journalID: JournalID(rawValue: "journal"))
        let result = decoder.feed([resultLine], startingAt: 1, journalID: JournalID(rawValue: "journal"))

        let running = try #require(toolRunPayload(in: call, seq: 0))
        let completed = try #require(toolRunPayload(in: result, seq: 1))
        #expect(running.previewAttachments?.count == 1)
        #expect(completed.previewAttachments?.count == 1)
        let attachment = try #require(completed.previewAttachments?.first)
        #expect(attachment.kind == "image")
        #expect(attachment.hostPath == imageURL.path)
        #expect(attachment.displayName == imageURL.lastPathComponent)
        #expect(attachment.mimeType == "image/png")
        #expect(attachment.width == 1)
        #expect(attachment.height == 1)
        #expect(attachment.byteCount == Self.png1x1Data.count)
        #expect(attachment.authorRole == "agent")
    }

    @Test
    func codexViewImageToolCarriesInputGeometryBeforeFileLoads() throws {
        let imagePath = "/tmp/cmux-codex-pending-preview.png"
        let arguments = #"{"path":"\#(imagePath)","display_name":"pending-preview.png","mime_type":"image/png","width":640,"height":360,"aspect_ratio":1.7777777778}"#
        let callLine = #"{"type":"response_item","payload":{"type":"function_call","name":"view_image","call_id":"call_image","arguments":"\#(arguments.replacingOccurrences(of: "\"", with: "\\\""))"}}"#
        let resultLine = #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call_image","output":"queued preview"}}"#
        var decoder = CodexTranscriptDecoder()

        let call = decoder.feed([callLine], startingAt: 0, journalID: JournalID(rawValue: "journal"))
        let result = decoder.feed([resultLine], startingAt: 1, journalID: JournalID(rawValue: "journal"))

        let running = try #require(toolRunPayload(in: call, seq: 0))
        let completed = try #require(toolRunPayload(in: result, seq: 1))
        #expect(running.previewAttachments?.count == 1)
        #expect(completed.previewAttachments?.count == 1)
        let attachment = try #require(completed.previewAttachments?.first)
        #expect(attachment.kind == "image")
        #expect(attachment.hostPath == imagePath)
        #expect(attachment.displayName == "pending-preview.png")
        #expect(attachment.mimeType == "image/png")
        #expect(attachment.width == 640)
        #expect(attachment.height == 360)
        #expect(attachment.aspectRatio == 1.7777777778)
        #expect(attachment.byteCount == nil)
        #expect(attachment.authorRole == "agent")
    }

    @Test
    func claudeAttachmentRecordDerivesImageDimensionsFromFileHeader() throws {
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-attachment-\(UUID().uuidString).png")
        try Self.png1x1Data.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let line = #"{"type":"attachment","attachment":{"fileName":"fixture.png","path":"\#(imageURL.path)","mime_type":"image/png"}}"#
        var decoder = ClaudeTranscriptDecoder()
        let batch = decoder.feed([line], startingAt: 0, journalID: JournalID(rawValue: "journal"))

        #expect(kindTable(batch.entries) == ["0:attachment"])
        let attachment = try #require(attachmentPayload(in: batch, seq: 0))
        #expect(attachment.kind == "file")
        #expect(attachment.hostPath == imageURL.path)
        #expect(attachment.width == 1)
        #expect(attachment.height == 1)
        #expect(attachment.byteCount == Self.png1x1Data.count)
    }

    @Test
    func claudeSVGAttachmentRecordCarriesPreviewMetadata() throws {
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-svg-\(UUID().uuidString).svg")
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="480" height="270" viewBox="0 0 480 270"></svg>"#
        let data = Data(svg.utf8)
        try data.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let line = #"{"type":"attachment","attachment":{"fileName":"preview.svg","path":"\#(imageURL.path)"}}"#
        var decoder = ClaudeTranscriptDecoder()
        let batch = decoder.feed([line], startingAt: 0, journalID: JournalID(rawValue: "journal"))

        #expect(kindTable(batch.entries) == ["0:attachment"])
        let attachment = try #require(attachmentPayload(in: batch, seq: 0))
        #expect(attachment.hostPath == imageURL.path)
        #expect(attachment.mimeType == "image/svg+xml")
        #expect(attachment.width == 480)
        #expect(attachment.height == 270)
        #expect(attachment.byteCount == data.count)
    }

    @Test
    func claudeAssistantMarkdownImageEmitsPreviewMetadataInSourceOrder() throws {
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-markdown-\(UUID().uuidString).png")
        try Self.png1x1Data.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let line = #"{"type":"assistant","message":{"role":"assistant","content":"Before\n\n![Claude Preview](\#(imageURL.path))\n\nAfter"}}"#
        var decoder = ClaudeTranscriptDecoder()
        let batch = decoder.feed([line], startingAt: 0, journalID: JournalID(rawValue: "journal"))

        #expect(kindTable(batch.entries) == ["0:agentProse", "1:attachment", "2:agentProse"])
        let attachment = try #require(attachmentPayload(in: batch, seq: 1))
        #expect(attachment.hostPath == imageURL.path)
        #expect(attachment.displayName == "Claude Preview")
        #expect(attachment.mimeType == "image/png")
        #expect(attachment.width == 1)
        #expect(attachment.height == 1)
        #expect(attachment.byteCount == Self.png1x1Data.count)
        #expect(attachment.authorRole == "agent")
    }

    @Test
    func claudeViewImageToolCarriesPreviewMetadataThroughCompletion() throws {
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-view-image-\(UUID().uuidString).png")
        try Self.png1x1Data.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let callLine = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tool_image","name":"view_image","input":{"path":"\#(imageURL.path)"}}]}}"#
        let resultLine = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool_image","content":"loaded preview","is_error":false}]}}"#
        var decoder = ClaudeTranscriptDecoder()

        let call = decoder.feed([callLine], startingAt: 0, journalID: JournalID(rawValue: "journal"))
        let result = decoder.feed([resultLine], startingAt: 10, journalID: JournalID(rawValue: "journal"))

        let running = try #require(toolRunPayload(in: call, seq: 0))
        let completed = try #require(toolRunPayload(in: result, seq: 10))
        #expect(running.previewAttachments?.count == 1)
        #expect(completed.previewAttachments?.count == 1)
        let attachment = try #require(completed.previewAttachments?.first)
        #expect(attachment.kind == "image")
        #expect(attachment.hostPath == imageURL.path)
        #expect(attachment.displayName == imageURL.lastPathComponent)
        #expect(attachment.mimeType == "image/png")
        #expect(attachment.width == 1)
        #expect(attachment.height == 1)
        #expect(attachment.byteCount == Self.png1x1Data.count)
        #expect(attachment.authorRole == "agent")
    }

    @Test
    func claudeViewImageToolCarriesInputAspectRatioBeforeFileLoads() throws {
        let imagePath = "/tmp/cmux-claude-pending-preview.png"
        let callLine = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tool_image","name":"view_image","input":{"path":"\#(imagePath)","name":"pending-preview.png","media_type":"image/png","preview_aspect_ratio":"9:16"}}]}}"#
        let resultLine = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool_image","content":"queued preview","is_error":false}]}}"#
        var decoder = ClaudeTranscriptDecoder()

        let call = decoder.feed([callLine], startingAt: 0, journalID: JournalID(rawValue: "journal"))
        let result = decoder.feed([resultLine], startingAt: 10, journalID: JournalID(rawValue: "journal"))

        let running = try #require(toolRunPayload(in: call, seq: 0))
        let completed = try #require(toolRunPayload(in: result, seq: 10))
        #expect(running.previewAttachments?.count == 1)
        #expect(completed.previewAttachments?.count == 1)
        let attachment = try #require(completed.previewAttachments?.first)
        #expect(attachment.kind == "image")
        #expect(attachment.hostPath == imagePath)
        #expect(attachment.displayName == "pending-preview.png")
        #expect(attachment.mimeType == "image/png")
        #expect(attachment.width == nil)
        #expect(attachment.height == nil)
        #expect(attachment.aspectRatio == 9.0 / 16.0)
        #expect(attachment.byteCount == nil)
        #expect(attachment.authorRole == "agent")
    }

    @Test
    func claudeMixedProseAndTwoToolCallsRemainIndependentThroughResults() throws {
        let callLine = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I will inspect both."},{"type":"tool_use","id":"tool_a","name":"Bash","input":{"command":"echo a"}},{"type":"tool_use","id":"tool_b","name":"WebSearch","input":{"query":"b"}}]}}"#
        let firstResultLine = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool_a","content":"result a","is_error":false}]}}"#
        let secondResultLine = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool_b","content":"result b","is_error":false}]}}"#
        let journalID = JournalID(rawValue: "journal")
        var decoder = ClaudeTranscriptDecoder()

        let calls = decoder.feed([callLine], startingAt: 100, journalID: journalID)
        #expect(kindTable(calls.entries) == ["100:agentProse", "101:toolRun", "102:toolRun"])
        #expect(toolRunPayload(in: calls, seq: 101)?.toolCallID == "tool_a")
        #expect(toolRunPayload(in: calls, seq: 102)?.toolCallID == "tool_b")

        let firstResultOffset = 100 + (callLine + "\n").utf8.count
        let firstResult = decoder.feed([firstResultLine], startingAt: firstResultOffset, journalID: journalID)
        let secondResultOffset = firstResultOffset + (firstResultLine + "\n").utf8.count
        let secondResult = decoder.feed([secondResultLine], startingAt: secondResultOffset, journalID: journalID)
        let firstTool = try #require(firstResult.entries.first).content.payload
        let secondTool = try #require(secondResult.entries.first).content.payload
        guard case .toolRun(let completedA) = firstTool,
              case .toolRun(let completedB) = secondTool else {
            Issue.record("both results should retain independent structured tool payloads")
            return
        }
        #expect(completedA.toolCallID == "tool_a")
        #expect(completedA.output == "result a")
        #expect(completedB.toolCallID == "tool_b")
        #expect(completedB.output == "result b")
    }

    @Test
    func claudeToolResultImageContentEmitsPreviewAttachment() throws {
        let callLine = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tool_image","name":"Hook_Success","input":{"message":"created image"}}]}}"#
        let resultLine = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool_image","content":[{"type":"text","text":"created preview"},{"type":"image","file_name":"hook-success.png","source":{"type":"base64","media_type":"image/png","data":"\#(Self.png1x1Base64)"}}],"is_error":false}]}}"#
        let journalID = JournalID(rawValue: "journal")
        var decoder = ClaudeTranscriptDecoder()

        let call = decoder.feed([callLine], startingAt: 0, journalID: journalID)
        let result = decoder.feed([resultLine], startingAt: 10, journalID: journalID)

        #expect(kindTable(call.entries) == ["0:toolRun"])
        #expect(kindTable(result.entries) == ["10:toolRun", "11:attachment"])
        #expect(toolRunPayload(in: result, seq: 10)?.toolName == "Hook_Success")
        #expect(toolRunPayload(in: result, seq: 10)?.resultSummary == "created preview")
        let attachment = try #require(attachmentPayload(in: result, seq: 11))
        #expect(attachment.kind == "image")
        #expect(attachment.displayName == "hook-success.png")
        #expect(attachment.mimeType == "image/png")
        #expect(attachment.width == 1)
        #expect(attachment.height == 1)
        #expect(attachment.byteCount == Self.png1x1Data.count)
        #expect(result.embeddedImages.map(\.entrySeq) == [EntrySeq(rawValue: 11)])
    }

    @Test
    func claudeToolResultGenericAttachmentCarriesAgentRoleAndAspectRatio() throws {
        let callLine = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tool_attachment","name":"Hook_Success","input":{"message":"created preview"}}]}}"#
        let resultLine = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool_attachment","content":[{"type":"attachment","attachment":{"type":"image","fileName":"hook-preview","aspect_ratio":0.75}}],"is_error":false}]}}"#
        var decoder = ClaudeTranscriptDecoder()

        let call = decoder.feed([callLine], startingAt: 0, journalID: JournalID(rawValue: "journal"))
        let result = decoder.feed([resultLine], startingAt: 10, journalID: JournalID(rawValue: "journal"))

        #expect(kindTable(call.entries) == ["0:toolRun"])
        #expect(kindTable(result.entries) == ["10:toolRun", "11:attachment"])
        let attachment = try #require(attachmentPayload(in: result, seq: 11))
        #expect(attachment.kind == "image")
        #expect(attachment.displayName == "hook-preview")
        #expect(attachment.aspectRatio == 0.75)
        #expect(attachment.authorRole == "agent")
    }

    @Test
    func claudeAssistantMarkdownImageRatioMetadataSurvivesWithoutImageFile() throws {
        let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"![Claude Preview](/tmp/claude-preview.png \"ratio=0.75\")"}]}}"#
        var decoder = ClaudeTranscriptDecoder()
        let batch = decoder.feed([line], startingAt: 0, journalID: JournalID(rawValue: "journal"))

        #expect(kindTable(batch.entries) == ["0:attachment"])
        let attachment = try #require(attachmentPayload(in: batch, seq: 0))
        #expect(attachment.hostPath == "/tmp/claude-preview.png")
        #expect(attachment.width == nil)
        #expect(attachment.height == nil)
        #expect(attachment.aspectRatio == 0.75)
    }

    @Test
    func claudeIncrementalBoundariesMatchOneShot() throws {
        let lines = try fixtureLines("claude-synthetic")
        var oneShot = ClaudeTranscriptDecoder()
        let expected = oneShot.feed(lines, startingAt: 0, journalID: JournalID(rawValue: "journal"))
        for split in 0 ... lines.count {
            var decoder = ClaudeTranscriptDecoder()
            let first = decoder.feed(Array(lines.prefix(split)), startingAt: 0, journalID: JournalID(rawValue: "journal"))
            let second = decoder.feed(Array(lines.dropFirst(split)), startingAt: split, journalID: JournalID(rawValue: "journal"))
            #expect(first.entries + second.entries == expected.entries)
            #expect(mergedDiagnostics(first.diagnostics, second.diagnostics) == expected.diagnostics)
        }
    }

    @Test
    func codexIncrementalBoundariesMatchOneShot() throws {
        let lines = try fixtureLines("codex-synthetic")
        var oneShot = CodexTranscriptDecoder()
        let expected = oneShot.feed(lines, startingAt: 0, journalID: JournalID(rawValue: "journal"))
        for split in 0 ... lines.count {
            var decoder = CodexTranscriptDecoder()
            let first = decoder.feed(Array(lines.prefix(split)), startingAt: 0, journalID: JournalID(rawValue: "journal"))
            let second = decoder.feed(Array(lines.dropFirst(split)), startingAt: split, journalID: JournalID(rawValue: "journal"))
            #expect(first.entries + second.entries == expected.entries)
            #expect(mergedDiagnostics(first.diagnostics, second.diagnostics) == expected.diagnostics)
        }
    }

    private func fixtureLines(_ name: String) throws -> [String] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl"))
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private func kindTable(_ entries: [EntrySnapshot]) -> [String] {
        entries.map { "\($0.seq.rawValue):\($0.kind.rawValue)" }
    }

    private func payload(in batch: TranscriptDecodeBatch, seq: Int) -> EntryPayload? {
        batch.entries.first { $0.seq == EntrySeq(rawValue: seq) }?.content.payload
    }

    private func userMessagePayload(in batch: TranscriptDecodeBatch, seq: Int) -> UserMessagePayload? {
        if case .userMessage(let payload) = payload(in: batch, seq: seq) {
            return payload
        }
        return nil
    }

    private func toolRunPayload(in batch: TranscriptDecodeBatch, seq: Int) -> ToolRunPayload? {
        if case .toolRun(let payload) = payload(in: batch, seq: seq) {
            return payload
        }
        return nil
    }

    private func fileChangePayload(in batch: TranscriptDecodeBatch, seq: Int) -> FileChangePayload? {
        if case .fileChange(let payload) = payload(in: batch, seq: seq) {
            return payload
        }
        return nil
    }

    private func questionPayload(in batch: TranscriptDecodeBatch, seq: Int) -> QuestionPayload? {
        if case .question(let payload) = payload(in: batch, seq: seq) {
            return payload
        }
        return nil
    }

    private func attachmentPayload(in batch: TranscriptDecodeBatch, seq: Int) -> AttachmentPayload? {
        if case .attachment(let payload) = payload(in: batch, seq: seq) {
            return payload
        }
        return nil
    }

    private func statusPayload(in batch: TranscriptDecodeBatch, seq: Int) -> StatusPayload? {
        if case .status(let payload) = payload(in: batch, seq: seq) {
            return payload
        }
        return nil
    }

    private func unknownPayload(in batch: TranscriptDecodeBatch, seq: Int) -> UnknownPayload? {
        if case .unknown(let payload) = payload(in: batch, seq: seq) {
            return payload
        }
        return nil
    }

    private func mergedDiagnostics(
        _ first: TranscriptDecoderDiagnostics,
        _ second: TranscriptDecoderDiagnostics
    ) -> TranscriptDecoderDiagnostics {
        TranscriptDecoderDiagnostics(
            unknownKindCounts: mergedCounts(first.unknownKindCounts, second.unknownKindCounts),
            modeledKindCounts: mergedCounts(first.modeledKindCounts, second.modeledKindCounts),
            duplicateStreamCounts: mergedCounts(first.duplicateStreamCounts, second.duplicateStreamCounts),
            bookkeepingKindCounts: mergedCounts(first.bookkeepingKindCounts, second.bookkeepingKindCounts),
            cliVersion: second.cliVersion ?? first.cliVersion,
            phaseFacts: first.phaseFacts + second.phaseFacts,
            turnContextFacts: first.turnContextFacts + second.turnContextFacts,
            sawApiError: first.sawApiError || second.sawApiError,
            sensitiveSessionTitles: first.sensitiveSessionTitles + second.sensitiveSessionTitles
        )
    }

    private func mergedCounts(_ first: [String: Int], _ second: [String: Int]) -> [String: Int] {
        first.merging(second) { lhs, rhs in lhs + rhs }
    }
}
