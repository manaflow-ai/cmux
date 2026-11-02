import CmuxMobileAgentChat
import Foundation
import Testing
@testable import CmuxMobileLive

/// The acpmux side of the phone's chat rows (cmux#25834 slice C): the records they read, the
/// prompt blocks a video or a PDF goes as, `/status`'s fields and Resume's call.
@Suite struct ChatRowsParityLiveTests {
    let records = AcpmuxRecords(sessionID: "s1")

    func json(_ string: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8)) }

    @Test func turnResultNamesItsSeq() throws {
        let result = try json(#"{"seq":41,"dir":"mux","kind":"turn_result","msg":{"status":"completed","turnId":"t7"}}"#)
        let events = records.map(result)
        guard case .turnResult("t7", .completed, nil, _)? = events.first else { Issue.record("no result"); return }
        #expect(events.last == .turnSeq(turnId: "t7", seq: 41))
    }

    @Test @MainActor func queuePausesAndResumes() throws {
        let paused = try json(#"{"seq":5,"dir":"mux","kind":"queue_paused","msg":{"turnId":"t","held":["p2"]}}"#)
        #expect(records.map(paused) == [.queuePaused(true, reason: nil)])
        let stop = try json(#"{"seq":6,"dir":"mux","kind":"queue_paused","msg":{"held":["p3"],"reason":"stop"}}"#)
        #expect(records.map(stop) == [.queuePaused(true, reason: "stop")])
        let resumed = try json(#"{"seq":7,"dir":"mux","kind":"queue_resumed","msg":{"queued":1}}"#)
        #expect(records.map(resumed) == [.queuePaused(false, reason: nil)])
        // A chat opened after the pause record still knows it from its state.
        let state = try json(#"{"queuePaused":true}"#)
        #expect(AcpmuxSessionSource.sessionState(state) == [.queuePaused(true, reason: nil)])
    }

    @Test func userMessageLeavesOutTheVideoFrames() throws {
        let user = try json(#"""
        {"seq":4,"dir":"mux","kind":"user_message","msg":{"turnId":"t","promptId":"p","text":"what happens here?\nFrames from the video clip.mov (0:08, 640×360), in order, at: 0:01.0.\nclip.mov frame at 0:01.0","images":[{"id":"img1","name":"clip.mov frame at 0:01.0"},{"id":"img2","name":"photo.png"}]}}
        """#)
        guard case .userMessage(let text, _, _, let attachments, _)? = records.map(user).first else { Issue.record("no user message"); return }
        #expect(text == "what happens here?")
        #expect(attachments.map(\.recordedImageID) == ["img2"])
    }

    @Test @MainActor func videoGoesAsItsLinkThenItsFrames() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let video = AgentAttachment(id: "v", kind: .file, name: "clip.mov", fileURL: URL(fileURLWithPath: "/tmp/clip.mov"), byteCount: 900,
                                    video: AgentVideo(durationMs: 8_000, width: 640, height: 360, frames: [.init(atMs: 1_000, jpeg: jpeg)]))
        let blocks = AcpmuxSessionSource.promptBlocks(text: "what happens?", attachments: [video], uploaded: ["v": "/w/.cmux/attachments/clip.mov"])
        #expect(blocks.map { $0["type"]?.stringValue } == ["text", "resource_link", "text", "text", "image"])
        #expect(blocks[1]["uri"]?.stringValue == "file:///w/.cmux/attachments/clip.mov")
        #expect(blocks[2]["text"]?.stringValue == "Frames from the video clip.mov (0:08, 640×360), in order, at: 0:01.0.")
        #expect(blocks[3]["text"]?.stringValue == "clip.mov frame at 0:01.0")
        #expect(blocks[4]["name"]?.stringValue == "clip.mov frame at 0:01.0")
        #expect(blocks[4]["data"]?.stringValue == jpeg.base64EncodedString())
    }

    @Test @MainActor func smallPDFGoesAsADocument() {
        let pdf = Data("%PDF-1.7\n%%EOF".utf8)
        let attachment = AgentAttachment(id: "d", kind: .file, name: "brief.pdf", data: pdf)
        let blocks = AcpmuxSessionSource.promptBlocks(text: "summarize", attachments: [attachment])
        #expect(blocks.count == 2)
        #expect(blocks[1] == .object(["type": .string("document"), "mimeType": .string("application/pdf"),
                                      "data": .string(pdf.base64EncodedString()), "name": .string("brief.pdf")]))
        // Not a PDF's bytes, or past the cap: it goes as a link to its uploaded copy.
        #expect(AcpmuxSessionSource.documentData(AgentAttachment(kind: .file, name: "fake.pdf", data: Data("hello".utf8))) == nil)
        let large = AgentAttachment(kind: .file, name: "big.pdf", data: Data("%PDF".utf8) + Data(count: AgentAttachment.maxDocumentBytes))
        #expect(AcpmuxSessionSource.documentData(large) == nil)
    }

    @Test @MainActor func pdfsPastTheInlineBudgetGoAsLinks() {
        let pdf = { (id: String) in AgentAttachment(id: id, kind: .file, name: "\(id).pdf", data: Data("%PDF".utf8) + Data(count: 7 << 20)) }
        let attachments = [pdf("a"), pdf("b"), pdf("c")]
        #expect(AcpmuxSessionSource.inlineDocuments(attachments) == ["a", "b"])
        let blocks = AcpmuxSessionSource.promptBlocks(text: "", attachments: attachments, uploaded: ["c": "/w/c.pdf"])
        #expect(blocks.map { $0["type"]?.stringValue } == ["document", "document", "resource_link"])
    }

    @Test func statusReadsOnlyLabelsAndTheAuthSource() throws {
        let info = try json(#"""
        {"sessionId":"s-123","harness":"claude","cwd":"/Users/me/proj","model":"claude-opus-5-5",
         "configOptions":[{"id":"effort","currentValue":"medium"}],
         "agentInfo":{"version":"2.5.1","authSource":"Claude subscription","apiKey":"sk-secret","baseUrl":"https://router.example.com:8443/v1/x"},
         "usage":{"used":25000,"size":100000},
         "usageLimits":{"windows":[{"id":"session","usedPercent":12.4}]}}
        """#)
        let status = AcpmuxSessionSource.sessionStatus(info, macName: "Studio", fallbackHarness: "Claude")
        let fields = Dictionary(uniqueKeysWithValues: status.fields.map { ($0.label, $0.value) })
        #expect(status.harness == "claude")
        #expect(fields["Version"] == "2.5.1")
        #expect(fields["Session"] == "s-123")
        #expect(fields["CWD"] == "/Users/me/proj")
        #expect(fields["Host"] == "Studio")
        #expect(fields["Model"] == "claude-opus-5-5")
        #expect(fields["Effort"] == "medium")
        #expect(fields["Auth source"] == "Claude subscription")
        #expect(fields["Routing"] == "https://router.example.com:8443")
        #expect(fields["Settings"] == "Not reported")
        #expect(fields["Context"]?.hasPrefix("25%") == true)
        #expect(fields["Usage limits"] == "Session 12%")
        #expect(!status.copyText.contains("sk-secret"), "no other agentInfo value is ever shown")
    }
}
