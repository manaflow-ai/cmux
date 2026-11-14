import CmuxNextCompat
import Darwin
import Foundation
import Testing
@testable import CmuxNextDaemon

/// The app side of the slow request log (P0 2026-11-10: a split showed no terminal and no log said whether
/// the daemon was slow). Each request the app waited more than 100 ms for, each timeout, each error reply and
/// each rolled-back intent leaves one JSON line in a bounded file; no line holds content.
///
/// The tests drive the real transport against a daemon on a thread of this process, with an injected clock:
/// the durations come from the clock, never from a real wait.
@Suite(.timeLimit(.minutes(2))) struct SlowRequestLogTests {
    private static let workspace = "ws_0123456789abcdef0123456789abcdef"
    private static let pane = "pane_fedcba9876543210fedcba9876543210"

    @Test func aRequestAnsweredAfter150msGivesOneRecordAndA5msOneGivesNone() async throws {
        let fixture = try Fixture()
        defer { fixture.stop() }

        let slow = Task {
            try await fixture.transport.request(cmd: "split", timeout: .seconds(5)) { id in
                Data(#"{"id":\#(id),"cmd":"split","pane":7,"surface":12,"workspace":"\#(Self.workspace)"}"#.utf8)
            }
        }
        let arrived1 = await fixture.daemon.waitForRequests(1)
        #expect(arrived1, "the daemon did not read request 1")
        fixture.clock.advance(milliseconds: 150)
        fixture.daemon.answerHeld { id in #"{"id":\#(id),"ok":true,"data":{"pane":9}}"# }
        let reply = try await slow.value

        let fast = Task {
            try await fixture.transport.request(cmd: "list-workspaces", timeout: .seconds(5)) { id in
                Data(#"{"id":\#(id),"cmd":"list-workspaces"}"#.utf8)
            }
        }
        let arrived2 = await fixture.daemon.waitForRequests(2)
        #expect(arrived2, "the daemon did not read request 2")
        fixture.clock.advance(milliseconds: 5)
        fixture.daemon.answerHeld { id in #"{"id":\#(id),"ok":true,"data":{}}"# }
        _ = try await fast.value

        let lines = await fixture.lines()
        #expect(lines.count == 1, "one slow request and one fast one must leave exactly one record: \(lines)")
        let record = try #require(lines.first.flatMap(Fixture.object))
        #expect(record["kind"] as? String == "request")
        #expect(record["side"] as? String == "app")
        #expect(record["name"] as? String == "split")
        #expect(record["total_ms"] as? Double == 150.0)
        #expect(record["outcome"] as? String == "ok")
        #expect(record["timeout_ms"] as? Int == 5000)
        #expect(record["reply_bytes"] as? Int == reply.line.count)
        #expect(record["pane"] as? Int == 7)
        #expect(record["surface"] as? Int == 12)
        #expect(record["workspace"] as? String == Self.workspace)
        #expect(record["at_ms"] as? UInt64 == Fixture.wallStart)
        #expect(record["at"] as? String == "2026-11-10T15:20:01.123Z")
        #expect(record["error"] == nil)
        // The keys come in the order of the format.
        let expected = #"{"kind":"request","side":"app","at":"2026-11-10T15:20:01.123Z","at_ms":1794324001123,"name":"split","#
            + #""workspace":"\#(Self.workspace)","pane":7,"surface":12,"total_ms":150.0,"reply_bytes":\#(reply.line.count),"#
            + #""timeout_ms":5000,"outcome":"ok"}"#
        #expect(lines.first == expected)
    }

    @Test func aTimeoutGivesARecord() async throws {
        let fixture = try Fixture()
        defer { fixture.stop() }
        let request = Task {
            try await fixture.transport.request(cmd: "new-tab", timeout: .seconds(30)) { id in
                Data(#"{"id":\#(id),"cmd":"new-tab","pane":3}"#.utf8)
            }
        }
        let arrived1 = await fixture.daemon.waitForRequests(1)
        #expect(arrived1, "the daemon did not read request 1")
        // The deadline passes on the injected clock; the transport's own deadline timer calls the same `expire`.
        fixture.clock.advance(milliseconds: 30000)
        fixture.transport.expire(id: 1, after: .seconds(30))
        let result = await request.result
        guard case .failure(let failure) = result, case DaemonError.timedOut = failure else {
            Issue.record("the request did not time out: \(result)")
            return
        }
        let lines = await fixture.lines()
        #expect(lines.count == 1, "a timed-out request must leave one record: \(lines)")
        let record = try #require(lines.first.flatMap(Fixture.object))
        #expect(record["name"] as? String == "new-tab")
        #expect(record["outcome"] as? String == "timed_out")
        #expect(record["total_ms"] as? Double == 30000.0)
        #expect(record["timeout_ms"] as? Int == 30000)
        #expect(record["pane"] as? Int == 3)
        #expect(record["reply_bytes"] == nil)
    }

    @Test func anErrorReplyGivesARecordWithTheCodeAndWithoutTheMessage() async throws {
        let fixture = try Fixture()
        defer { fixture.stop() }
        let refused = Task {
            try await fixture.transport.request(cmd: "pane.split", timeout: .seconds(5)) { id in
                Data(#"{"protocol":"cmux.protocol/2","type":"request","id":"\#(id)","operation":"pane.split","params":{"pane":"\#(Self.pane)"}}"#.utf8)
            }
        }
        let arrived1 = await fixture.daemon.waitForRequests(1)
        #expect(arrived1, "the daemon did not read request 1")
        fixture.clock.advance(milliseconds: 2)
        fixture.daemon.answerHeld { id in
            #"{"id":"\#(id)","ok":false,"error":{"code":"selector.not_found","message":"no pane for ~/Documents/secret-plan.txt"}}"#
        }
        let result = await refused.result
        guard case .failure(let failure) = result, case DaemonError.command = failure else {
            Issue.record("the request was not refused: \(result)")
            return
        }
        // A code outside the grammar `[a-z0-9_.-]{1,48}` is recorded as the word `error`.
        let odd = Task {
            try await fixture.transport.request(cmd: "rename-tab", timeout: .seconds(5)) { id in
                Data(#"{"id":\#(id),"cmd":"rename-tab","surface":4,"name":"my private tab"}"#.utf8)
            }
        }
        let arrived2 = await fixture.daemon.waitForRequests(2)
        #expect(arrived2, "the daemon did not read request 2")
        fixture.daemon.answerHeld { id in #"{"id":\#(id),"ok":false,"error":"cannot rename my private tab","error_code":"Bad Code: my private tab"}"# }
        _ = await odd.result

        let lines = await fixture.lines()
        #expect(lines.count == 2, "each error reply must leave one record: \(lines)")
        let first = try #require(lines.first.flatMap(Fixture.object))
        #expect(first["name"] as? String == "pane.split")
        #expect(first["outcome"] as? String == "error")
        #expect(first["error"] as? String == "selector.not_found")
        #expect(first["pane"] as? String == Self.pane)
        #expect(first["total_ms"] as? Double == 2.0)
        let second = try #require(lines.last.flatMap(Fixture.object))
        #expect(second["name"] as? String == "rename-tab")
        #expect(second["error"] as? String == "error")
        #expect(second["surface"] as? Int == 4)
        let text = await fixture.fileText()
        #expect(!text.contains("secret-plan"), "an error message reached the file")
        #expect(!text.contains("private"), "a request param or an error message reached the file")
        #expect(!text.contains("Bad Code"), "a code outside the grammar reached the file")
    }

    @Test func aParamThatIsNotOnTheAllowListIsNotInTheFile() async throws {
        let fixture = try Fixture()
        defer { fixture.stop() }
        // `text` is typed input; `pane` and `terminal` hold text where an id belongs; `cwd` and `url` are not listed.
        let legacy = Task {
            try await fixture.transport.request(cmd: "send", timeout: .seconds(5)) { id in
                Data((#"{"id":\#(id),"cmd":"send","surface":12,"text":"echo hunter2 > ~/.ssh/id_key","pane":"ls -la /Users/me","#
                    + #""terminal":"aaaabbbbccccddddeeeeffff00001111","cwd":"/Users/me/taxes","url":"https://example.com/?token=abc123","#
                    + #""workspace":"\#(Self.workspace)","tab":true,"screen":-4}"#).utf8)
            }
        }
        let arrived1 = await fixture.daemon.waitForRequests(1)
        #expect(arrived1, "the daemon did not read request 1")
        fixture.clock.advance(milliseconds: 250)
        fixture.daemon.answerHeld { id in #"{"id":\#(id),"ok":true,"data":{"echo":"hunter2 output"}}"# }
        _ = try await legacy.value

        let resource = Task {
            try await fixture.transport.request(cmd: "terminal.create", timeout: .seconds(5)) { id in
                Data((#"{"protocol":"cmux.protocol/2","type":"request","id":"\#(id)","operation":"terminal.create","#
                    + #""credential":"cred_topsecret","idempotency_key":"client-chosen-key","surface":99,"#
                    + #""params":{"pane":"\#(Self.pane)","command":"vim passwords.txt","machine":"current","session":"current","browser":3}}"#).utf8)
            }
        }
        let arrived2 = await fixture.daemon.waitForRequests(2)
        #expect(arrived2, "the daemon did not read request 2")
        fixture.clock.advance(milliseconds: 250)
        fixture.daemon.answerHeld { id in #"{"id":"\#(id)","ok":true,"data":{}}"# }
        _ = try await resource.value

        let lines = await fixture.lines()
        #expect(lines.count == 2, "each slow request must leave one record: \(lines)")
        let first = try #require(lines.first.flatMap(Fixture.object))
        #expect(Set(first.keys) == ["kind", "side", "at", "at_ms", "name", "workspace", "surface", "total_ms", "reply_bytes", "timeout_ms", "outcome"],
                "only the listed ids with an id's form may be in the record: \(first.keys.sorted())")
        #expect(first["surface"] as? Int == 12)
        let second = try #require(lines.last.flatMap(Fixture.object))
        #expect(Set(second.keys) == ["kind", "side", "at", "at_ms", "name", "pane", "browser", "total_ms", "reply_bytes", "timeout_ms", "outcome"],
                "a resource request's ids come from its params only: \(second.keys.sorted())")
        #expect(second["pane"] as? String == Self.pane)
        let text = await fixture.fileText()
        for secret in ["hunter2", "ssh", "ls -la", "/Users/me", "taxes", "token", "example.com", "aaaabbbbccccdddd",
                       "topsecret", "client-chosen-key", "vim", "passwords", "current", "echo"] {
            #expect(!text.contains(secret), "\(secret) reached the file")
        }
    }

    @MainActor @Test func aRolledBackIntentGivesARecord() async throws {
        let fixture = try Fixture()
        defer { fixture.stop() }
        let store = DaemonStore()
        store.slowRequestLog = fixture.log
        let pane = PaneID(rawValue: 3)
        let base = WorkspaceSnapshot(
            id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000001"), name: "1",
            screens: [ScreenSnapshot(id: ScreenID(rawValue: 2), active: true, activePane: pane, layout: .leaf(pane),
                                     panes: [PaneSnapshot(id: pane, tabs: [TabSnapshot(surface: SurfaceID(rawValue: 4))])])])
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [base]))

        let transaction = ClientTransactionID.generate()
        store.intend(.renameTab(surface: SurfaceID(rawValue: 4), name: "my secret project"), transaction: transaction)
        fixture.clock.advance(milliseconds: 320)
        store.rejectIntent(transaction, failure: DaemonError.command(cmd: "rename-tab", message: "cannot rename my secret project",
                                                                     code: "tab.not_found"))
        // A transaction that is not pending rolls nothing back: no record.
        store.rejectIntent(transaction, failure: DaemonError.notConnected)
        store.rejectIntent(.generate())

        let lines = await fixture.lines()
        #expect(lines.count == 1, "one rolled-back intent must leave exactly one record: \(lines)")
        let expected = #"{"kind":"rollback","side":"app","at":"2026-11-10T15:20:01.123Z","at_ms":1794324001123,"#
            + #""name":"rename-tab","total_ms":320.0,"error":"tab.not_found"}"#
        #expect(lines.first == expected)
        let text = await fixture.fileText()
        #expect(!text.contains("secret"), "an intent's value or an error message reached the file")
    }

    @Test func tenThousandRecordsLeaveAtMostTheStatedBytesAndTheNewestAreThere() async throws {
        let fixture = try Fixture()
        defer { fixture.stop() }
        let line = Data(#"{"id":1,"cmd":"split","pane":"\#(Self.pane)","workspace":"\#(Self.workspace)","surface":12}"#.utf8)
        let total = 10000
        // In groups below the queue's limit, each group written before the next: no record is dropped.
        for group in stride(from: 0, to: total, by: 200) {
            for index in group..<(group + 200) {
                fixture.log.noteRequest(name: "split", line: line, nanoseconds: 200_000_000 + UInt64(index) * 1_000_000,
                                        replyBytes: 420, timeout: .seconds(5), failure: nil)
            }
            await fixture.log.flushed()
        }
        #expect(fixture.log.droppedCount == 0)
        let current = fixture.directory.appendingPathComponent(SlowRequestLog.fileName).path
        let sizes = [current, current + ".1"].map { path -> Int in
            var info = stat()
            return stat(path, &info) == 0 ? Int(info.st_size) : -1
        }
        #expect(SlowRequestLog.maxFileBytes == 1_048_576)
        #expect(sizes.allSatisfy { $0 > 0 && $0 <= SlowRequestLog.maxFileBytes }, "each file holds records and at most 1 MiB: \(sizes)")
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted()
        #expect(names == [SlowRequestLog.fileName, SlowRequestLog.fileName + ".1"], "only the file and one rotated copy: \(names)")
        var info = stat()
        #expect(stat(current, &info) == 0 && info.st_mode & 0o777 == 0o600, "the file's mode must be 0600")
        // The newest record is the last line; the two files hold a run of the newest records with no gap.
        let rotated = ((try? String(contentsOfFile: current + ".1", encoding: .utf8)) ?? "").split(separator: "\n").map { String($0) }
        let newest = await fixture.lines()
        let kept = rotated + newest
        let totals = kept.compactMap { Fixture.object($0)?["total_ms"] as? Double }
        #expect(totals.count == kept.count, "every kept line is one whole JSON object")
        #expect(totals.last == Double(200 + total - 1), "the newest record is not the last line: \(String(describing: totals.last))")
        #expect(totals.count > 2000, "two files of 1 MiB hold thousands of records, found \(totals.count)")
        #expect(zip(totals, totals.dropFirst()).allSatisfy { $1 == $0 + 1 }, "the kept records are not the newest run")
    }

    /// The rotated copy cannot be made here (its name is a folder): the file must still stay below the limit.
    @Test func aRotationThatFailsDoesNotLetTheFilePassTheLimit() throws {
        let fixture = try Fixture()
        defer { fixture.stop() }
        let current = fixture.directory.appendingPathComponent(SlowRequestLog.fileName)
        try FileManager.default.createDirectory(atPath: current.path + ".1", withIntermediateDirectories: false)
        try Data(repeating: 0x61, count: SlowRequestLog.maxFileBytes - 10).write(to: current)
        let line = String(repeating: "b", count: 200)
        for _ in 0..<3 {
            SlowRequestLogFile(directory: fixture.directory).append(line)
        }
        let written = try Data(contentsOf: current)
        #expect(written.count <= SlowRequestLog.maxFileBytes, "the file passed 1 MiB: \(written.count) bytes")
        #expect(written.suffix(201) == Data((line + "\n").utf8), "the newest record is not the last line")
    }

    @Test func aBlockedWriterNeverMakesTheRequestPathWaitAndTheDropCountGoesUp() async throws {
        let gate = WriterGate()
        let fixture = try Fixture(emit: { _ in gate.hold() })
        defer { fixture.stop() }
        defer { gate.release() }
        func note(_ index: Int) {
            fixture.log.noteRequest(name: "split", line: nil, nanoseconds: 200_000_000 + UInt64(index) * 1_000_000,
                                    replyBytes: nil, timeout: nil, failure: nil)
        }
        // The writer takes the first record and stops in its sink.
        note(0)
        let writerHeld = await gate.waitUntilHeld()
        #expect(writerHeld, "the writer never took a record")
        // The queue fills, then 25 more records come: each call returns at once (this test goes on while the
        // writer is still held) and the 25 are counted, not waited for.
        for index in 1...SlowRequestLog.queueLimit { note(index) }
        #expect(fixture.log.droppedCount == 0)
        for index in 1...25 { note(SlowRequestLog.queueLimit + index) }
        #expect(gate.isHeld, "the writer was not blocked while the records came")
        #expect(fixture.log.droppedCount == 25)

        gate.release()
        await fixture.log.flushed()
        note(9000)
        let lines = await fixture.lines()
        #expect(lines.count == 1 + SlowRequestLog.queueLimit + 2, "the kept records, one dropped record and the next record: \(lines.count)")
        let dropped = lines.compactMap(Fixture.object).filter { $0["kind"] as? String == "dropped" }
        #expect(dropped.count == 1)
        #expect(dropped.first?["queue_full"] as? Int == 25)
        #expect(dropped.first?["side"] as? String == "app")
        // The dropped record comes before the record made after the drops.
        let kinds = lines.compactMap(Fixture.object).map { $0["kind"] as? String ?? "" }
        #expect(kinds.dropLast().last == "dropped" && kinds.last == "request", "the order of the last records: \(kinds.suffix(3))")
    }
}

/// A transport with the log, a daemon on a thread, an injected clock and a folder of its own.
private struct Fixture: Sendable {
    /// 2026-11-10T15:20:01.123Z.
    static let wallStart: UInt64 = 1_794_324_001_123

    let clock: TestUptime
    let log: SlowRequestLog
    let daemon: ScriptedDaemon
    let transport: LineTransport
    let directory: URL

    init(emit: @escaping @Sendable (String) -> Void = { _ in }) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("slow-request-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let clock = TestUptime()
        self.clock = clock
        log = SlowRequestLog(uptime: { clock.now }, wallMilliseconds: { Self.wallStart }, emit: emit)
        log.setDirectory(directory)
        daemon = try ScriptedDaemon()
        transport = try LineTransport(path: daemon.path, slowLog: log)
        transport.start(onEvent: { _, _, _ in }, onClose: { _ in })
    }

    func stop() {
        transport.close()
        daemon.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    /// The file's text once the writer wrote every record made so far.
    func fileText() async -> String {
        await log.flushed()
        return (try? String(contentsOf: directory.appendingPathComponent(SlowRequestLog.fileName), encoding: .utf8)) ?? ""
    }

    func lines() async -> [String] {
        await fileText().split(separator: "\n").map { String($0) }
    }

    static func object(_ line: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }
}

/// Monotonic nanoseconds that only the test moves.
private final class TestUptime: Sendable {
    private let value = Mutex<UInt64>(5_000_000_000)
    var now: UInt64 { value.withLock { $0 } }
    func advance(milliseconds: UInt64) { value.withLock { $0 += milliseconds * 1_000_000 } }
}

/// Holds the log's writer in its sink until released.
private final class WriterGate: Sendable {
    private struct State {
        var held = false
        var released = false
    }
    private let condition = NSCondition()
    private let state = Mutex(State())

    var isHeld: Bool { state.withLock { $0.held && !$0.released } }

    /// On the writer queue: waits until ``release()``.
    func hold() {
        condition.lock()
        state.withLock { $0.held = true }
        while !state.withLock({ $0.released }) { condition.blockingWait() }
        condition.unlock()
    }

    func release() {
        condition.lock()
        state.withLock { $0.released = true }
        condition.broadcast()
        condition.unlock()
    }

    /// At most 10 s.
    func waitUntilHeld() async -> Bool {
        for _ in 0..<1000 {
            if state.withLock({ $0.held }) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

/// A unix socket served by a thread of the test process: it keeps every request until the test answers it.
private final class ScriptedDaemon: @unchecked Sendable { // crash-allow: the fd is written once in init and closed once in stop
    let path: String
    private let descriptor: Int32
    private struct State {
        var received = 0
        var held: [(client: Int32, id: String)] = []
    }
    private let state = Mutex(State())

    init() throws {
        path = "/tmp/srl-\(UUID().uuidString.prefix(8)).sock"
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = path
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else { throw POSIXError(.EADDRINUSE) }
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { return }
                Thread.detachNewThread { self.serve(client) }
            }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(client, &chunk, chunk.count, 0)
            guard count > 0 else { return }
            buffer += Data(chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                // A legacy line has a numeric id, a `cmux.protocol/2` request a decimal string.
                let id = (object["id"] as? String) ?? (object["id"] as? Int).map { String($0) } ?? "0"
                state.withLock { state in
                    state.received += 1
                    state.held.append((client, id))
                }
            }
        }
    }

    /// Waits (at most 10 s) until `count` requests came in all.
    func waitForRequests(_ count: Int) async -> Bool {
        for _ in 0..<1000 {
            if state.withLock({ $0.received }) >= count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// Answers every request kept so far with the line `reply` makes for its id.
    func answerHeld(_ reply: (String) -> String) {
        let held = state.withLock { state -> [(client: Int32, id: String)] in
            defer { state.held = [] }
            return state.held
        }
        for request in held {
            let line = Data((reply(request.id) + "\n").utf8)
            _ = line.withUnsafeBytes { send(request.client, $0.baseAddress, line.count, 0) }
        }
    }

    func stop() {
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
        unlink(path)
    }
}
