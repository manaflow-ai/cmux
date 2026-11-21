import Foundation
import os
import Testing
@testable import CmuxNextDaemon

/// The closed state of a starting terminal's input (`CreatingTerminalInput.close()`): what leaves the app
/// after the person closed the view, over a fixture bridge that records each `send` and each
/// `cancel-creating-input`. No user daemon is started.
///
/// These are tests of the type's new surface (`close()`, `cancels:`): they have no form on a tree before it.
struct CreatingTerminalInputCloseTests {
    private struct Calls: DaemonRequest {
        typealias Response = JSONValue
        static let command = "test-calls"
    }

    /// The fixture daemon. It queues each chunk, but: the chunk `hold` gets no answer until a cancel comes, and is
    /// then refused (as the daemon refuses a chunk that was on its way at the cancel); the chunk `refuse` is refused at once.
    private static let script = #"""
    import base64, json, sys
    calls = []
    held = None
    print('{"ok":true}', file=sys.stderr, flush=True)
    def answer(frame, data):
        print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
    def refuse(frame):
        print(json.dumps({'id': frame.get('id'), 'ok': False, 'error': 'input for this terminal was cancelled', 'code': 'input.cancelled'}), flush=True)
    for line in sys.stdin:
        frame = json.loads(line)
        cmd = frame.get('cmd')
        if cmd == 'identify':
            answer(frame, {'app': 'cmux-tui', 'protocol': 12, 'generation': 'creating-input-close', 'capabilities': []})
        elif cmd == 'send':
            text = base64.b64decode(frame.get('bytes') or '').decode()
            calls.append({'cmd': cmd, 'terminal_id': frame.get('terminal_id'), 'text': text})
            if text == 'hold':
                held = frame
            elif text == 'refuse':
                refuse(frame)
            else:
                answer(frame, {'queued': True})
        elif cmd == 'cancel-creating-input':
            calls.append({'cmd': cmd, 'terminal_id': frame.get('terminal_id')})
            answer(frame, {'cancelled': True})
            if held is not None:
                refuse(held)
                held = None
        elif cmd == 'test-calls':
            answer(frame, calls)
        else:
            answer(frame, {})
    """#

    private static let terminal = "51000000000040008000000000000001"

    private static func withConnection(_ body: (DaemonConnection) async throws -> Void) async throws {
        let endpoint = DaemonEndpoint(socketPath: "/tmp/cmux-creating-input-close-\(UUID().uuidString).sock", bridge: DaemonBridge.fakePython(["-c", script]))
        let connection = DaemonConnection(endpoint: endpoint, configuration: .init(requiredCapabilities: [], terminalEnvironment: nil))
        do {
            try await connection.start()
            try await body(connection)
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }

    /// What the fixture got, as `send:<text>` and `cancel`, in order.
    private static func calls(_ connection: DaemonConnection) async throws -> [String] {
        let reply = try await connection.request(Calls())
        let got = try #require(reply.arrayValue, "the fixture's call list is no array")
        return got.map { call in
            #expect(call["terminal_id"] == .string(terminal), "a request names another terminal: \(call)")
            return call["cmd"] == .string("send") ? "send:\(call["text"]?.stringValue ?? "?")" : "cancel"
        }
    }

    /// Waits until the fixture got `call` (the cancel leaves in a task of its own; a held chunk is on its way).
    private static func waitFor(_ call: String, on connection: DaemonConnection) async throws -> [String] {
        var got: [String] = []
        for _ in 0..<300 {
            got = try await calls(connection)
            if got.contains(call) { return got }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the daemon never got \(call): \(got)")
        return got
    }

    @Test func aClosedViewSendsOneCancelAndNoLaterChunk() async throws {
        try await Self.withConnection { connection in
            let input = CreatingTerminalInput(terminalID: Self.terminal, connection: connection, cancels: true) { false }
            #expect(await input.write(Data("ls".utf8)), "a chunk of a starting view did not go by the terminal id")
            #expect(input.close(), "the first close of the view sent no cancel")
            #expect(!input.close(), "a second close of the view sent a second cancel")
            #expect(await input.write(Data("\r".utf8)), "a chunk of a closed view was not taken: it would go to the attach queue")
            _ = try await Self.waitFor("cancel", on: connection)
            // One more round trip: nothing else is on its way.
            let got = try await Self.calls(connection)
            #expect(got == ["send:ls", "cancel"], "what the daemon got after the close is not one cancel and no later chunk")
        }
    }

    @Test func anOlderDaemonIsSentNoCancelAndALaterChunkStillLeavesNothing() async throws {
        try await Self.withConnection { connection in
            let input = CreatingTerminalInput(terminalID: Self.terminal, connection: connection, cancels: false) { false }
            #expect(await input.write(Data("ls".utf8)))
            #expect(!input.close(), "a daemon with no creating-input-cancel-v1 was sent a cancel")
            #expect(await input.write(Data("\r".utf8)), "a chunk of a closed view was not taken")
            let got = try await Self.calls(connection)
            #expect(got == ["send:ls"], "an older daemon got more than the chunk sent before the close")
        }
    }

    /// A chunk that was on its way when the person closed the view: the daemon refuses it. It is dropped, not
    /// given to the attach queue (which would write it to the terminal when it starts).
    @Test func aChunkTheDaemonRefusesForAClosedViewIsDropped() async throws {
        try await Self.withConnection { connection in
            let input = CreatingTerminalInput(terminalID: Self.terminal, connection: connection, cancels: true) { false }
            async let refused = input.write(Data("hold".utf8))
            _ = try await Self.waitFor("send:hold", on: connection)
            #expect(input.close())
            #expect(await refused, "a chunk the daemon refused for a closed view goes to the attach queue")
            let got = try await Self.waitFor("cancel", on: connection)
            #expect(got == ["send:hold", "cancel"], "what the daemon got is not the held chunk and one cancel")
        }
    }

    /// The control of the test above: a refused chunk of a view that is NOT closed goes by the attachment, as before.
    @Test func aChunkTheDaemonRefusesForAViewThatIsNotClosedGoesByTheAttachment() async throws {
        try await Self.withConnection { connection in
            let input = CreatingTerminalInput(terminalID: Self.terminal, connection: connection, cancels: true) { false }
            #expect(await !input.write(Data("refuse".utf8)), "a refused chunk of an open view was dropped")
            #expect(await !input.write(Data("x".utf8)), "after a refusal a chunk still went by the terminal id")
            let got = try await Self.calls(connection)
            #expect(got == ["send:refuse"], "a chunk went by the terminal id after the refusal")
        }
    }

    /// The daemon refused the close and the view stayed: once its terminal is made, input goes by the attachment again.
    @Test func aClosedViewWhoseTerminalStartedAllTheSameTakesInputByTheAttachmentAgain() async throws {
        try await Self.withConnection { connection in
            let known = OSAllocatedUnfairLock(initialState: false)
            let input = CreatingTerminalInput(terminalID: Self.terminal, connection: connection, cancels: true) { known.withLock { $0 } }
            #expect(input.close())
            #expect(await input.write(Data("a".utf8)), "a chunk of a closed view whose terminal is not made was not dropped")
            known.withLock { $0 = true }
            #expect(await !input.write(Data("b".utf8)), "a chunk for a terminal that started did not go by the attachment")
            let got = try await Self.waitFor("cancel", on: connection)
            #expect(got == ["cancel"], "a chunk of a closed view left the app")
        }
    }
}
