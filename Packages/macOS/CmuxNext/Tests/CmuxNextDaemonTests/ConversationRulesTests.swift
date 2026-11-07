import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextDaemon

/// The conversation client rules answer through the cmux SDK's C ABI (`cmux_sdk_conversation_rule`), and the
/// Swift call sites read them right. The rules themselves are tested by the SDK's golden vectors
/// (cmux-tui/bindings/rust/tests/cases/conversation_rules.json); these check the wiring.
struct ConversationRulesTests {
    @Test func aPageSizeIsClampedByTheSDK() {
        #expect(ConversationSnapshotRequest(conversation: "c", tail: 0).tail == 1)
        #expect(ConversationHistoryRequest(conversation: "c", beforeSeq: 9, limit: 900).limit == 500)
        #expect(ConversationThreadRequest(conversation: "c", root: "r", afterSeq: 0, limit: 42).limit == 42)
    }

    @Test func aPartsPlainTextIsTheSDKs() {
        let attachment = ConversationAttachment(hash: "h", name: "photo.png", mimeType: "image/png", byteCount: 3)
        #expect(ConversationPart.text("hi", runs: []).plainText == "hi")
        #expect(ConversationPart.work(session: "s1", host: nil, status: "running", preview: nil).plainText == "s1 running")
        #expect(ConversationPart.work(session: "s1", host: nil, status: "running", preview: "done").plainText == "done")
        #expect(ConversationPart.attachment(attachment).plainText == "photo.png")
        #expect(ConversationPart.linkPreview(ConversationLinkPreview(url: "https://a.b")).plainText == "https://a.b")
        #expect(ConversationPart.unknown(type: "poll", payload: .object(["type": .string("poll")])).plainText == "poll")
        #expect(ConversationPart.unknown(type: "card", payload: .object(["type": .string("card"), "url": .string("https://c.d")])).plainText
            == "https://c.d")
    }

    @Test func inboxOpValuesAreTheSDKs() {
        let unpin = ConversationInboxOpRequest.Op.pin(false, position: 3)
        #expect(unpin.kind == "inbox.pin" && unpin.pinned == false && unpin.position == nil)
        let pin = ConversationInboxOpRequest.Op.pin(true, position: 3)
        #expect(pin.pinned == true && pin.position == 3)
        let unread = ConversationInboxOpRequest.Op.markUnread(true)
        #expect(unread.kind == "inbox.mark_unread" && unread.unread == true && unread.pinned == nil)
        #expect(ConversationInboxOpRequest.Op.mute(false, until: 5).until == nil)
        #expect(ConversationInboxOpRequest.Op.mute(true, until: 5) == .mute(true, until: 5))
        #expect(ConversationInboxOpRequest.Op.mute(true, until: 5).until == 5)
    }

    @Test func aRunToolIsNormalizedByTheSDK() throws {
        let envelope = #"{"tool": "mcp_tool_call", "arguments": {"server": "optchat", "tool": "tell", "arguments": {"id": "a1", "message": "hi", "_meta": {"cmux": {"sender": "human:p"}}}}, "status": "done", "started_at": 12.5}"#
        let tool = try JSONDecoder().decode(ConversationRunTool.self, from: Data(envelope.utf8))
        #expect(tool.name == "mcp_tool_call")
        #expect(tool.input?.isTellEnvelope == true && tool.input?.isSpawnEnvelope == false)
        #expect(tool.input?.id == "a1" && tool.input?.message == "hi" && tool.input?.sender == "human:p")
        #expect(tool.status == "done" && tool.startedAt == 12.5)
        // Any shape still decodes.
        let odd = try JSONDecoder().decode(ConversationRunTool.self, from: Data(#"{"name": "edit", "input": [1, 2], "status": 7}"#.utf8))
        #expect(odd.name == "edit" && odd.status == nil && odd.input?.id == nil)
        #expect(try JSONDecoder().decode(ConversationRunTool.self, from: Data("3".utf8)).name.isEmpty)
    }

    @Test func aMissingPosterIsRefusedByTheRule() {
        let attachment = ConversationAttachment(hash: "h", name: "v.mp4", mimeType: "video/mp4", byteCount: 3)
        #expect(throws: ConversationRules.Failure.refused(rule: "upload_plan", code: "poster_needed")) {
            try ConversationRules().uploadPlan(attachment: attachment, needs: [.original, .poster], hasPosterFile: false, hasPreviewFile: false)
        }
        #expect(throws: ConversationRules.Failure.refused(rule: "read_next", code: "no_progress")) {
            try ConversationRules().readNext(offset: 4, received: 0, eof: false)
        }
    }

    /// An upload in the SDK's chunks and a read on its cursor, through the production client and a fixture daemon.
    @Test func anAttachmentRoundTripsInTheSDKsChunks() async throws {
        let script = #"""
        import base64, json, sys
        pieces, chunks = {}, []
        print('{"ok":true}', file=sys.stderr, flush=True)
        for line in sys.stdin:
            frame = json.loads(line)
            command = frame.get('cmd')
            result = {}
            if command == 'identify':
                result = {'app':'cmux-tui', 'protocol':12, 'generation':'attachment-test', 'capabilities':['local-attachments-v1']}
            elif command == 'conversation-attachment-upload':
                op = frame['op']
                if op == 'begin':
                    result = {'upload':'u1', 'needs':['original', 'preview']}
                elif op == 'chunk':
                    data = base64.b64decode(frame['data'])
                    chunks.append([frame['piece'], frame['offset'], len(data)])
                    pieces[frame['piece']] = pieces.get(frame['piece'], b'') + data
                    result = {'received': len(pieces[frame['piece']])}
                elif op == 'commit':
                    result = {'stored':{'hash':'h', 'mime_type':'application/octet-stream', 'byte_count':len(pieces['original'])}}
            elif command == 'conversation-attachment-read':
                body = pieces.get(frame['variant'], b'')
                part = body[frame['offset']:frame['offset'] + frame['length']]
                result = {'hash':'h', 'mime_type':'application/x-test', 'byte_count':len(body), 'offset':frame['offset'],
                          'data':base64.b64encode(part).decode(), 'eof':frame['offset'] + len(part) >= len(body)}
            elif command == 'test-chunks':
                result = chunks
            print(json.dumps({'id':frame.get('id'), 'ok':True, 'data':result}), flush=True)
        """#
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let chunk = 4 << 20
        let original = Data((0..<(2 * chunk + 1000)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let preview = Data("preview bytes".utf8)
        let file = directory.appendingPathComponent("original.bin")
        let previewFile = directory.appendingPathComponent("preview.webp")
        try original.write(to: file)
        try preview.write(to: previewFile)
        let attachment = ConversationAttachment(hash: "h", name: "original.bin", mimeType: "application/octet-stream", byteCount: original.count,
                                                preview: ConversationDerivedImage(hash: "p", mimeType: "image/webp", byteCount: preview.count))

        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", script])
        let connection = DaemonConnection(
            endpoint: .init(socketPath: "/tmp/cmux-attachment-rules-\(UUID().uuidString).sock", bridge: bridge),
            configuration: .init(requiredCapabilities: [], terminalEnvironment: nil))
        do {
            try await connection.start()
            let client = ConversationClient(connection)
            let reported = ProgressLog()
            let stored = try await client.uploadAttachment(conversation: "c", attachment: attachment, file: file, previewFile: previewFile,
                                                           progress: { value in reported.values.withLock { $0.append(value) } })
            #expect(stored.byteCount == original.count)
            let calls = try #require(try await connection.request(CapturedChunks()).arrayValue)
            let sent = calls.map { $0.arrayValue ?? [] }
            #expect(sent == [[.string("original"), .number(0), .number(Double(chunk))],
                             [.string("original"), .number(Double(chunk)), .number(Double(chunk))],
                             [.string("original"), .number(Double(2 * chunk)), .number(1000)],
                             [.string("preview"), .number(0), .number(Double(preview.count))]])
            let progress = reported.values.withLock { $0 }
            #expect(progress.count == 5 && progress.last == 1)
            let sending = Array(progress.dropLast())
            #expect(sending.allSatisfy { $0 <= 0.99 } && sending == sending.sorted())

            let destination = directory.appendingPathComponent("read.bin")
            let mimeType = try await client.downloadAttachment(conversation: "c", hash: "h", variant: .original, to: destination)
            #expect(mimeType == "application/x-test")
            #expect(try Data(contentsOf: destination) == original)
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }

    private final class ProgressLog: Sendable {
        let values = Mutex<[Double]>([])
    }

    private struct CapturedChunks: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-chunks"
    }
}
