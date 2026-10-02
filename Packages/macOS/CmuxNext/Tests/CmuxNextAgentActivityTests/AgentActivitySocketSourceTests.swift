import AppKit
@testable import CmuxNextAgentActivity
import Darwin
import Foundation
import Testing

/// A tiny line-JSON Unix socket server standing in for the CUA host.
nonisolated final class FakeCuaHost: @unchecked Sendable {
    let path: String
    private let fd: Int32
    private let lock = NSLock()
    private var requests: [[String: Any]] = []
    private var subscribers: [Int32] = []
    let handler: @Sendable ([String: Any]) -> [String: Any]

    init(handler: @escaping @Sendable ([String: Any]) -> [String: Any]) throws {
        path = NSTemporaryDirectory() + "cua-\(UUID().uuidString.prefix(8)).sock"
        self.handler = handler
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { raw in path.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) } }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        guard withUnsafePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }) == 0,
              listen(fd, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    var received: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return requests }

    func push(_ result: [String: Any]) {
        lock.lock(); let targets = subscribers; lock.unlock()
        for client in targets { write(client, ["ok": true, "result": result]) }
    }

    func close() { Darwin.close(fd); unlink(path) }

    private func acceptLoop() {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { return }
            Thread.detachNewThread { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(client, &chunk, chunk.count)
            if n <= 0 { Darwin.close(client); return }
            buffer.append(contentsOf: chunk[0..<n])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard var json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if let request = json["request"] as? [String: Any] { json = request.merging(["_auth": json["host_auth_token"] ?? NSNull()]) { a, _ in a } }
                lock.lock(); requests.append(json); lock.unlock()
                if json["method"] as? String == "activity_subscribe" {
                    lock.lock(); subscribers.append(client); lock.unlock()
                    write(client, ["ok": true, "result": handler(json)])
                } else {
                    write(client, handler(json))
                }
            }
        }
    }

    private func write(_ client: Int32, _ object: [String: Any]) {
        var data = try! JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        _ = data.withUnsafeBytes { Darwin.write(client, $0.baseAddress, data.count) }
    }
}

@MainActor
struct AgentActivitySocketSourceTests {
    nonisolated(unsafe) static let record: [String: Any] = [
        "id": "cua_n_1", "label": "fill-form", "color": "#30A46C", "started_at_ms": 1_000, "last_action_at_ms": 5_000,
        "status": ["state": "active"], "targets": [["app_name": "TextEdit", "pid": 9]],
        "counters": ["acts": 2, "observes": 1, "errors": 0, "frames": 1, "bytes": 0],
        "agent": ["attribution": "process_tree", "kind": "claude", "class": "agent", "actor": "agent:1",
                  "terminal_id": "term_7", "workspace_id": "ws_2"],
    ]

    nonisolated(unsafe) static let page: [String: Any] = [
        "next_seq": 2,
        "events": [
            ["session": "cua_n_1", "seq": 0, "ts_ms": 1_000, "tx": "t", "kind": "session_start", "actor": "agent:1", "origin": "mcp"],
            ["session": "cua_n_1", "seq": 1, "ts_ms": 2_000, "tx": "t", "kind": "act", "tool": "type_text", "actor": "agent:1",
             "origin": "mcp", "args_redacted": ["text": ["redacted": "text", "length": 9]], "after_frame": "ab.jpg",
             "click_point": ["x": 640, "y": 400], "result": ["ok": true, "verified": true], "duration_ms": 12],
        ],
        "frames": ["ab.jpg": ["width": 320, "height": 200, "source_width": 1280, "source_height": 800, "expired": false]],
    ]

    @Test func wireMapsRecordsAndEvents() throws {
        let session = try #require(AgentActivityWire.session(Self.record, machine: "local", machineName: "This Mac"))
        #expect(session.agentName == "Claude Code")
        #expect(session.attribution == .processTree)
        #expect(session.targetApps == ["TextEdit"])
        #expect(session.status == .active)
        #expect(session.lastActionAt == Date(timeIntervalSince1970: 5))
        let events = AgentActivityWire.events(Self.page)
        #expect(events.map(\.seq) == [0, 1])
        #expect(events[1].redactedTextLength == 9)
        #expect(events[1].afterFrame?.width == 320)
        #expect(events[1].clickPoint == CGPoint(x: 0.5, y: 0.5))
        #expect(AgentActivityWire.status(["state": "ended", "reason": "user_stop"]) == .ended(.userStop))
    }

    @Test func requestLinesCarryTheHostCredential() throws {
        let line = AgentActivityWire.requestLine(method: "activity_session_stop", args: ["id": "x"], authToken: "a", hostAuthToken: "h")
        let json = try #require(try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
        #expect(json["auth_token"] as? String == "a")
        #expect(json["host_auth_token"] as? String == "h")
        #expect((json["request"] as? [String: Any])?["method"] as? String == "activity_session_stop")
    }

    @Test func socketSourceStreamsSessionsFetchesTimelinesAndSendsStop() async throws {
        let host = try FakeCuaHost { request in
            switch request["method"] as? String {
            case "activity_subscribe": ["type": "sessions", "sessions": [Self.record]]
            case "activity_timeline": ["ok": true, "result": Self.page]
            case "activity_session_stop": ["ok": true, "result": ["applied": true]]
            default: ["ok": false, "error": "unknown"]
            }
        }
        defer { host.close() }
        let source = AgentActivitySocketSource(configuration: .init(socketPath: host.path, authToken: "a", hostAuthToken: "h",
                                                                    machineName: "This Mac"))
        let model = AgentActivityModel(source: source)
        model.start()
        try await eventually { model.selectedSessionID == "cua_n_1" }
        try await eventually { model.selectedEvents.count == 2 }
        #expect(model.connections[AgentActivityModel.localMachine] == .connected)
        model.perform(.stop(session: "cua_n_1"))
        try await eventually { host.received.contains { $0["method"] as? String == "activity_session_stop" } }
        let stop = try #require(host.received.first { $0["method"] as? String == "activity_session_stop" })
        #expect(stop["_auth"] as? String == "h")
        #expect(model.selectedSession?.status == .active, "the host decides; no optimistic change")
        host.push(["type": "sessions", "sessions": [Self.record.merging(["status": ["state": "ended", "reason": "user_stop"]]) { _, b in b }]])
        try await eventually { model.selectedSession?.status == .ended(.userStop) }
    }

    @Test func missingSocketShowsNotStarted() async throws {
        let source = AgentActivitySocketSource(configuration: .init(socketPath: NSTemporaryDirectory() + "absent-\(UUID()).sock",
                                                                    machineName: "This Mac"))
        let model = AgentActivityModel(source: source)
        model.start()
        try await eventually { model.connections[AgentActivityModel.localMachine] == .notStarted }
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("condition not met")
    }
}
