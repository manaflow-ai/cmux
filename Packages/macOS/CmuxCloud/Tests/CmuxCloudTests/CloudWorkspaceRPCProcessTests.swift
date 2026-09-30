import Foundation
import Testing
@testable import CmuxCloud

/// Drives ``CloudWorkspaceRPCProcess`` against a scripted `remote rpc --stream` peer.
@Suite struct CloudWorkspaceRPCProcessTests {
    /// Speaks the stream protocol: `{"ready":true}`, then one answer per id. A request
    /// `path` selects behavior: `missing` answers an RPC error, `delay:<s>` answers late
    /// on its own thread, `exit` ends the process. Cancel lines are appended to argv[1].
    private static let fakeStream = #"""
import json, os, sys, threading, time
log = sys.argv[1]
lock = threading.Lock()
def emit(obj):
    with lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()
emit({"ready": True})
for line in sys.stdin:
    msg = json.loads(line)
    if msg.get("cancel"):
        with open(log, "a") as f:
            f.write("cancel %s\n" % msg["id"])
        continue
    path = msg["request"].get("path", "")
    with open(log, "a") as f:
        f.write("request %s\n" % msg["id"])
    if path == "exit":
        os._exit(3)
    if path == "missing":
        emit({"id": msg["id"], "error": {"code": "not-found", "message": "path not found", "retryable": False}})
        continue
    def answer(msg=msg, path=path):
        if path.startswith("delay:"):
            time.sleep(float(path.split(":")[1]))
        emit({"id": msg["id"], "result": {"type": "echo", "path": path}})
    threading.Thread(target=answer).start()
"""#

    private actor Releases {
        private(set) var count = 0
        func release() { count += 1 }
    }

    private func start(log: URL, releases: Releases) async throws -> CloudWorkspaceRPCProcess {
        let process = CloudWorkspaceRPCProcess()
        try await process.start(
            client: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-u", "-c", Self.fakeStream, log.path],
            releaseHub: { await releases.release() }
        )
        return process
    }

    private func request(_ process: CloudWorkspaceRPCProcess, path: String) async throws -> String? {
        let body = try JSONSerialization.data(withJSONObject: ["type": "read-file", "path": path])
        let data = try await process.request(body)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["path"] as? String
    }

    /// Waits until the fake peer has logged `line`, so a test acts only after the
    /// request actually reached the peer.
    private func waitForLog(_ log: URL, contains line: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: log, encoding: .utf8), text.contains(line) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("peer never logged \(line)")
    }

    private func temporaryLog() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cmux-rpc-stream-\(UUID().uuidString).log")
    }

    @Test("an RPC error answers only its request and keeps the channel open")
    func rpcErrorKeepsChannelOpen() async throws {
        let log = temporaryLog()
        defer { try? FileManager.default.removeItem(at: log) }
        let process = try await start(log: log, releases: Releases())
        defer { Task { await process.stop() } }
        await #expect(throws: CloudWorkspaceRPCProcess.RemoteError(code: "not-found", message: "path not found")) {
            _ = try await request(process, path: "missing")
        }
        #expect(await process.isReady)
        #expect(try await request(process, path: "after") == "after")
    }

    @Test("concurrent requests are matched to their own answers by id")
    func concurrentRequestsRouteById() async throws {
        let log = temporaryLog()
        defer { try? FileManager.default.removeItem(at: log) }
        let process = try await start(log: log, releases: Releases())
        defer { Task { await process.stop() } }
        async let slow = request(process, path: "delay:0.4")
        async let fast = request(process, path: "fast")
        #expect(try await fast == "fast")
        #expect(try await slow == "delay:0.4")
    }

    @Test("canceling a caller sends cancel for its id and leaves the channel usable")
    func cancellationSendsCancelLine() async throws {
        let log = temporaryLog()
        defer { try? FileManager.default.removeItem(at: log) }
        let process = try await start(log: log, releases: Releases())
        defer { Task { await process.stop() } }
        let waiting = Task { try await request(process, path: "delay:30") }
        try await waitForLog(log, contains: "request 1\n")
        waiting.cancel()
        await #expect(throws: CancellationError.self) { _ = try await waiting.value }
        // The next answer is ordered after the cancel line on the peer's stdin.
        #expect(try await request(process, path: "later") == "later")
        let lines = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        #expect(lines.contains("cancel 1"))
    }

    @Test("a peer exit fails in-flight requests and releases the claim once")
    func peerExitFailsPendingRequests() async throws {
        let log = temporaryLog()
        defer { try? FileManager.default.removeItem(at: log) }
        let releases = Releases()
        let process = try await start(log: log, releases: releases)
        let waiting = Task { try await request(process, path: "delay:30") }
        try await waitForLog(log, contains: "request 1\n")
        await #expect(throws: CloudMachineLink.LinkError.self) {
            _ = try await request(process, path: "exit")
        }
        await #expect(throws: CloudMachineLink.LinkError.self) { _ = try await waiting.value }
        #expect(await !process.isReady)
        await process.stop()
        #expect(await releases.count == 1)
    }
}
