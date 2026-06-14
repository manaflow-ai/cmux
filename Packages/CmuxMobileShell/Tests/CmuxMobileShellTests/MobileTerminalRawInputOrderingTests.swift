import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

// Regression coverage for https://github.com/manaflow-ai/cmux/issues/6082:
// fast typing on iOS arrived scrambled on the Mac because every keystroke from
// the libghostty surface was dispatched as its own independent
// `Task { await submitTerminalRawInput(...) }`. Independent unstructured tasks
// do not preserve creation order, and each awaited its own `terminal.input`
// RPC, so concurrent in-flight sends could be reordered by the transport.
//
// The fix routes surface bytes through ``MobileShellComposite``'s synchronous,
// coalescing FIFO (`rawTerminalInputBuffer`): synchronous enqueues preserve
// call order and a single drain loop delivers one ordered `terminal.input` at a
// time. The test drives keystrokes the same way the surface delegate does
// (synchronously on the main actor) and asserts they reach the Mac as a single
// in-order request rather than one unordered RPC per keystroke.

@MainActor
@Test func rapidRawSurfaceInputCoalescesIntoOneOrderedRequest() async throws {
    let box = RawInputTransportBox()
    let clock = TestClock()
    let runtime = LivenessTestRuntime(
        transportFactory: RawInputTransportFactory(box: box),
        now: { clock.now },
        // No push/subscribe handshake: this test scopes the connection to the
        // workspace.list + terminal.input request pair the ordering depends on.
        supportsServerPushEvents: false
    )
    let store = MobileShellComposite.preview(runtime: runtime)
    store.signIn()
    let ticket = try makeTicket(clock: clock)
    let connected = await store.connectPairingURL(try attachURL(for: ticket))
    #expect(connected, "scripted connect must succeed")

    // The surface-id resolution inside sendTerminalRawInput needs the workspace
    // list (and its live-terminal) to have landed first.
    let populated = try await pollUntil {
        store.workspaces.contains { workspace in
            workspace.terminals.contains { $0.id.rawValue == "live-terminal" }
        }
    }
    #expect(populated, "workspace list with live-terminal must populate before sending input")

    // Three keystrokes arrive synchronously on the main actor, exactly as
    // GhosttySurfaceView delivers fast typing through its delegate.
    store.sendTerminalRawInput(Data("a".utf8), surfaceID: "live-terminal")
    store.sendTerminalRawInput(Data("b".utf8), surfaceID: "live-terminal")
    store.sendTerminalRawInput(Data("c".utf8), surfaceID: "live-terminal")

    // Wait for input to start flowing, then settle long enough that any
    // erroneous per-keystroke sends would also have landed.
    _ = try await pollUntil {
        let count = await box.transport?.terminalInputCount() ?? 0
        return count >= 1
    }
    try await Task.sleep(nanoseconds: 150_000_000)

    let texts = await box.transport?.terminalInputTextsSnapshot() ?? []
    // Single, strictly-ordered request. The pre-fix path emitted one unordered
    // `terminal.input` per keystroke (e.g. ["a", "b", "c"] or any permutation).
    #expect(texts == ["abc"])
}

// MARK: - Scripted host that records terminal.input order

/// Captures the live transport instance so the test can read back the order of
/// `terminal.input` requests the store delivered.
final class RawInputTransportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: RawInputRecordingTransport?

    var transport: RawInputRecordingTransport? {
        lock.withLock { stored }
    }

    func set(_ transport: RawInputRecordingTransport) {
        lock.withLock { stored = transport }
    }
}

struct RawInputTransportFactory: CmxByteTransportFactory {
    let box: RawInputTransportBox

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        let transport = RawInputRecordingTransport()
        box.set(transport)
        return transport
    }
}

/// Answers the connect-time `workspace.list` and every `terminal.input`,
/// recording each input request's text in the exact order it was sent so the
/// test can assert ordering and coalescing.
actor RawInputRecordingTransport: CmxByteTransport {
    private var terminalInputTexts: [String] = []
    private var pendingFrames: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var isClosed = false

    func terminalInputCount() -> Int { terminalInputTexts.count }
    func terminalInputTextsSnapshot() -> [String] { terminalInputTexts }

    func connect() async throws {}

    func receive() async throws -> Data? {
        if !pendingFrames.isEmpty {
            return pendingFrames.removeFirst()
        }
        if isClosed {
            return nil
        }
        return await withCheckedContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }

    func send(_ data: Data) async throws {
        var buffer = data
        let payloads = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
        for payload in payloads {
            let parsed = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
            let method = parsed?["method"] as? String
            let id = parsed?["id"] as? String
            let params = parsed?["params"] as? [String: Any]
            if method == "terminal.input", let text = params?["text"] as? String {
                terminalInputTexts.append(text)
            }
            if let response = try? Self.response(method: method, id: id) {
                deliver(response)
            }
        }
    }

    func close() async {
        isClosed = true
        let waiters = receiveWaiters
        receiveWaiters = []
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    private func deliver(_ frame: Data) {
        if receiveWaiters.isEmpty {
            pendingFrames.append(frame)
            return
        }
        receiveWaiters.removeFirst().resume(returning: frame)
    }

    private static func response(method: String?, id: String?) throws -> Data? {
        switch method {
        case "workspace.list", "mobile.workspace.list":
            return try resultFrame(id: id, result: [
                "workspaces": [
                    [
                        "id": "live-workspace",
                        "title": "Live Workspace",
                        "current_directory": "/Users/test/project",
                        "is_selected": true,
                        "terminals": [
                            [
                                "id": "live-terminal",
                                "title": "Terminal",
                                "current_directory": "/Users/test/project",
                                "is_ready": true,
                                "is_focused": true,
                            ],
                        ],
                    ],
                ],
            ])
        case "terminal.input":
            return try resultFrame(id: id, result: [
                "workspace_id": "live-workspace",
                "surface_id": "live-terminal",
                "queued": false,
                "terminal_seq": 1,
            ])
        default:
            // Benign acknowledgement for any stray handshake RPC so the
            // connection stays up without scripting every method.
            return try resultFrame(id: id, result: [:])
        }
    }

    private static func resultFrame(id: String?, result: [String: Any]) throws -> Data {
        let envelope: [String: Any] = [
            "id": id ?? UUID().uuidString,
            "ok": true,
            "result": result,
        ]
        return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
    }
}
