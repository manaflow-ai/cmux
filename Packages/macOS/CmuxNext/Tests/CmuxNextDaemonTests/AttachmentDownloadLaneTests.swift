import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextDaemon

/// p02-threads-053 (plans/cmux-next/chrome-parity/p02-threads.md, maybe-main-blocking): `AttachmentTransfer.download`
/// against a real connection to a test bridge that serves `conversation-attachment-read` in two chunks. Every disk step
/// (the partial file's create, one write per chunk, the finish or the discard) runs on the files lane, and a read that
/// fails partway or whose caller is cancelled leaves neither a partial file nor a destination.
@Suite(.timeLimit(.minutes(1))) struct AttachmentDownloadLaneTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "attachment-download-\(UUID().uuidString)", directoryHint: .isDirectory)

    /// How the bridge answers the second chunk (offset 6): with its bytes, with an error, or with its bytes a second late.
    enum SecondChunk: String { case whole, fail, stall }

    @Test func aWholeReadWritesEveryChunkOnTheFilesLaneAndLandsTheBytes() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (runs, work) = Self.lanes()
        let destination = root.appending(path: "cache/abc-original.txt")

        let mimeType = try await withTransfer(.whole) { transfer in
            try await transfer.download(conversation: "c1", hash: "abc", variant: .original, to: destination, on: work)
        }

        #expect(mimeType == "text/plain")
        #expect(try Data(contentsOf: destination) == Data("hello world".utf8))
        #expect(await Self.first(4, of: runs) == [.files, .files, .files, .files], "create, two writes and the finish")
        #expect(try leftovers() == ["abc-original.txt"])
    }

    @Test func aReadThatFailsPartwayLeavesNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (runs, work) = Self.lanes()
        let destination = root.appending(path: "cache/abc-poster.jpg")

        await #expect(throws: DaemonError.self) {
            try await withTransfer(.fail) { transfer in
                try await transfer.download(conversation: "c1", hash: "abc", variant: .original, to: destination, on: work)
            }
        }

        #expect(await Self.first(3, of: runs) == [.files, .files, .files], "create, one write and the posted discard")
        #expect(try leftovers().isEmpty)
    }

    @Test func aCancelledReadLeavesNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (runs, work) = Self.lanes()
        let destination = root.appending(path: "cache/abc-preview.mp4")

        let outcome = try await withTransfer(.stall) { transfer in
            let read = Task { try await transfer.download(conversation: "c1", hash: "abc", variant: .original, to: destination, on: work) }
            // The create and the first chunk's write ran; the second chunk is a second away.
            #expect(await Self.first(2, of: runs) == [.files, .files])
            read.cancel()
            return await read.result
        }

        #expect(throws: CancellationError.self) { try outcome.get() }
        #expect(await Self.first(1, of: runs) == [.files], "the posted discard did not run")
        #expect(try leftovers().isEmpty)
    }

    // MARK: - Fixture

    /// A `BackgroundWork` and the lane of every item it ran, in order.
    static func lanes() -> (AsyncStream<BlockingLane>, BackgroundWork) {
        let (runs, ran) = AsyncStream.makeStream(of: BlockingLane.self)
        return (runs, BackgroundWork(label: "test.attachment-download", onRan: { lane, _, _, _ in ran.yield(lane) }))
    }

    static func first(_ count: Int, of runs: AsyncStream<BlockingLane>) async -> [BlockingLane] {
        var seen: [BlockingLane] = []
        for await lane in runs {
            seen.append(lane)
            if seen.count == count { break }
        }
        return seen
    }

    /// Every name in the destination folder, hidden partial files included.
    func leftovers() throws -> [String] {
        let folder = root.appending(path: "cache")
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// Runs `body` with a transfer over a connection to the bridge, then closes the connection.
    func withTransfer<T: Sendable>(
        _ second: SecondChunk,
        _ body: (AttachmentTransfer<ConversationAttachmentUploadRequest, ConversationAttachmentReadRequest>) async throws -> T
    ) async throws -> T {
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.script, second.rawValue])
        let endpoint = DaemonEndpoint(socketPath: "/tmp/cmux-attachment-test-\(UUID().uuidString).sock", bridge: bridge)
        let connection = DaemonConnection(endpoint: endpoint, configuration: .init(requiredCapabilities: [], terminalEnvironment: nil))
        do {
            try await connection.start()
            let transfer = AttachmentTransfer<ConversationAttachmentUploadRequest, ConversationAttachmentReadRequest>(
                connection: connection, beginTimeout: nil, chunkTimeout: .seconds(10), commitTimeout: .seconds(10), readTimeout: .seconds(10))
            let result = try await body(transfer)
            await connection.close()
            return result
        } catch {
            await connection.close()
            throw error
        }
    }

    /// The bridge: `identify`, then `conversation-attachment-read` of "hello " at offset 0 and "world" (eof) at offset 6.
    static let script = #"""
    import base64, json, sys, time
    second = sys.argv[1]
    print('{"ok":true}', file=sys.stderr, flush=True)
    for line in sys.stdin:
        frame = json.loads(line)
        command = frame.get('cmd')
        reply = {'id': frame.get('id'), 'ok': True, 'data': {}}
        if command == 'identify':
            reply['data'] = {'app': 'cmux-tui', 'protocol': 12, 'generation': 'test-boot', 'capabilities': []}
        elif command == 'conversation-attachment-read':
            offset = frame['offset']
            chunk = b'hello ' if offset == 0 else b'world'
            if offset != 0 and second == 'fail':
                reply.update(ok=False, error='attachment unreadable', error_code='bad-request')
            else:
                if offset != 0 and second == 'stall':
                    time.sleep(1.0)
                reply['data'] = {'hash': 'abc', 'mime_type': 'text/plain', 'byte_count': 11, 'offset': offset,
                                 'data': base64.b64encode(chunk).decode(), 'eof': offset != 0}
        print(json.dumps(reply), flush=True)
    """#
}
