import CmuxNextCompat
import Foundation
import Sentry
import Testing
@testable import CmuxNextCrashReporting

/// p09-observability-075: every shipped Rust role's panic and hang logs reach Sentry through one forwarder. A hang
/// line (cmux-hang-watch `hangs-<pid>.jsonl`, schema 1) is an event whose crashed thread carries the hung stack
/// (`instruction_addr` = image address + offset) and whose debug_meta lists every image UUID; each line is sent
/// once across restarts, and nothing is sent while telemetry is off.
@Suite struct OwnerPanicForwarderTests {
    /// Records what the forwarder sends.
    final class Recorder: Sendable {
        /// One hang entry handed on: the thread it names and the process that wrote it.
        struct Entry: Sendable, Equatable {
            var thread: String
            var source: RustPanicSource
        }

        private let events = Mutex(0)
        private let hangs = Mutex<[Entry]>([])

        /// How many events were captured.
        var sent: Int { events.withLock { $0 } }
        var hangEntries: [Entry] { hangs.withLock { $0 } }

        func capture(_: Event) { events.withLock { $0 += 1 } }
        func hang(_ record: RustHangRecord, _ source: RustPanicSource) {
            hangs.withLock { $0.append(Entry(thread: record.thread, source: source)) }
        }
    }

    static let cmuxUUID = "01234567-89ab-cdef-1032-547698badcfe"
    static let systemUUID = "fedcba98-7654-3210-0123-456789abcdef"

    /// A macOS hang line as `Hang::to_json_line` writes it: frames innermost first, one in libsystem_kernel, four in
    /// cmux-tui, one in no image, and two images.
    static func fixtureLine(thread: String = "mux-control-dispatch") -> String {
        let images = #"[{"uuid":"\#(cmuxUUID)","addr":4294967296,"size":1048576,"name":"cmux-tui"},"#
            + #"{"uuid":"\#(systemUUID)","addr":8589934592,"size":65536,"name":"libsystem_kernel.dylib"}]"#
        let frames = #"[{"addr":8589934608,"image":1,"offset":16},{"addr":4294971392,"image":0,"offset":4096},"#
            + #"{"addr":4294975488,"image":0,"offset":8192},{"addr":4294979584,"image":0,"offset":12288},"#
            + #"{"addr":4294983680,"image":0,"offset":16384},{"addr":7}]"#
        return #"{"schema":1,"pid":4242,"t_ns":99,"thread":"\#(thread)","kind":"control","native_thread_id":771,"#
            + #""slot":3,"deadline_ms":1000,"overdue_ms":2300,"stack":{"truncated":false,"frames":\#(frames),"images":\#(images)}}"#
            + "\n"
    }

    /// A Linux line: the thread and the deadline, no stack.
    static let stacklessLine = #"{"schema":1,"pid":9,"t_ns":1,"thread":"holder-poll","kind":"io","native_thread_id":5,"#
        + #""slot":0,"deadline_ms":500,"overdue_ms":40}"# + "\n"

    static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "rust-diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func append(_ text: String, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    static func hangLog(_ dir: URL, source: RustPanicSource = .owner) -> RustDiagnosticsLog {
        RustDiagnosticsLog(directory: dir.appending(path: "hangs/daemon"), name: .pattern(prefix: "hangs-", suffix: ".jsonl"),
                           source: source, kind: .hang)
    }

    static func forwarder(_ logs: [RustDiagnosticsLog], dir: URL, sends: Bool = true, recorder: Recorder) -> OwnerPanicForwarder {
        let forwarder = OwnerPanicForwarder(logs: logs, stateFile: dir.appending(path: "state.json"), sends: sends,
                                            capture: { recorder.capture($0) })
        forwarder.setHangEntries { recorder.hang($0, $1) }
        return forwarder
    }

    @Test func theFixtureLineGivesFramesAndDebugMetaListingEveryUUID() throws {
        let record = try #require(RustHangRecord(line: Data(Self.fixtureLine().utf8)))
        let event = record.event(source: .owner)

        let thread = try #require(event.threads?.first)
        #expect(event.threads?.count == 1)
        #expect(thread.name == "mux-control-dispatch")
        #expect(thread.crashed?.boolValue == true)
        let frames = try #require(thread.stacktrace?.frames)
        // Sentry runs outermost first: the line's last frame (in no image) comes first, its first frame last.
        #expect(frames.map(\.instructionAddress) == ["0x7", "0x100004000", "0x100003000", "0x100002000", "0x100001000", "0x200000010"])
        #expect(frames.map(\.imageAddress) == [nil, "0x100000000", "0x100000000", "0x100000000", "0x100000000", "0x200000000"])
        #expect(frames.map { $0.inApp?.boolValue } == [false, true, true, true, true, false])
        #expect(event.exceptions?.first?.stacktrace?.frames.count == 6)
        #expect(event.exceptions?.first?.type == "RustHang")

        let images = try #require(event.debugMeta)
        #expect(Set(images.compactMap(\.debugID)) == [Self.cmuxUUID, Self.systemUUID], "every UUID of the line")
        #expect(images.count == 2)
        let cmux = try #require(images.first { $0.debugID == Self.cmuxUUID })
        #expect(cmux.imageAddress == "0x100000000")
        #expect(cmux.imageSize?.uint64Value == 1_048_576)
        #expect(cmux.codeFile == "cmux-tui")
        #expect(cmux.type == "macho")

        // The thread's name and the innermost three in-app frames; the system frame is skipped.
        #expect(event.fingerprint == ["cmux-tui-hang", "mux-control-dispatch", "cmux-tui+0x1000", "cmux-tui+0x2000", "cmux-tui+0x3000"])
        #expect(event.tags?["process"] == "cmux-tui")
        #expect(event.tags?["hang.thread"] == "mux-control-dispatch")
        #expect(event.tags?["hang.thread_kind"] == "control")
        #expect(event.extra?["hang_overrun_ms"] as? Int == 2_300)
    }

    @Test func aLineWithoutAStackStillReportsTheThread() throws {
        let record = try #require(RustHangRecord(line: Data(Self.stacklessLine.utf8)))
        let event = record.event(source: .holder)
        #expect(event.threads?.first?.stacktrace == nil)
        #expect(event.debugMeta?.isEmpty == true)
        #expect(event.fingerprint == ["cmux-holder-hang", "holder-poll"])
        #expect(RustHangRecord(line: Data(#"{"schema":2,"pid":1}"#.utf8)) == nil, "another schema is not read")
    }

    @Test func eachLineIsForwardedOnceAcrossRestarts() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = Self.hangLog(dir)
        let file = log.directory.appending(path: "hangs-4242.jsonl")
        try Self.append(Self.fixtureLine(thread: "before-the-first-run"), to: file)
        let recorder = Recorder()

        // The first run marks the existing line read.
        #expect(Self.forwarder([log], dir: dir, recorder: recorder).forwardNew().isEmpty)
        try Self.append(Self.fixtureLine(), to: file)
        let first = Self.forwarder([log], dir: dir, recorder: recorder)
        #expect(first.forwardNew().count == 1)
        #expect(first.forwardNew().isEmpty)

        // A restart reads from the saved offset; a process that starts later is read from its first line.
        let restarted = Self.forwarder([log], dir: dir, recorder: recorder)
        #expect(restarted.forwardNew().isEmpty)
        try Self.append(Self.fixtureLine(thread: "journal-writer"), to: log.directory.appending(path: "hangs-4243.jsonl"))
        let sent = restarted.forwardNew()
        #expect(sent.map { $0.tags?["hang.thread"] } == ["journal-writer"])
        #expect(recorder.sent == 2)
        #expect(recorder.hangEntries.map(\.thread) == ["mux-control-dispatch", "journal-writer"])
        #expect(recorder.hangEntries.allSatisfy { $0.source == .owner })
    }

    @Test func nothingIsForwardedWhileTelemetryIsOff() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hangs = Self.hangLog(dir)
        let panics = RustDiagnosticsLog.file(dir.appending(path: "owner-panics-s.jsonl"), source: .owner, kind: .panic)
        let recorder = Recorder()
        #expect(Self.forwarder([hangs, panics], dir: dir, sends: false, recorder: recorder).forwardNew().isEmpty)
        try Self.append(Self.fixtureLine(), to: hangs.directory.appending(path: "hangs-1.jsonl"))
        try Self.append(#"{"message":"boom","location":"a.rs:1:1","thread":"w"}"# + "\n", to: panics.directory.appending(path: "owner-panics-s.jsonl"))

        #expect(Self.forwarder([hangs, panics], dir: dir, sends: false, recorder: recorder).forwardNew().isEmpty)
        #expect(recorder.sent == 0)
        #expect(recorder.hangEntries.isEmpty)
        // The lines of the time reports were off are never sent later.
        #expect(Self.forwarder([hangs, panics], dir: dir, sends: true, recorder: recorder).forwardNew().isEmpty)
        #expect(recorder.sent == 0)
    }

    @Test func anEarlierBuildsOffsetCarriesOver() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "owner-panics-s.jsonl")
        try Self.append(#"{"message":"sent before","location":"a.rs:1:1"}"# + "\n", to: file)
        let legacy = dir.appending(path: "owner-panic-forwarder.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = try #require((attributes[.size] as? NSNumber)?.uint64Value)
        let inode = try #require((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
        try JSONSerialization.data(withJSONObject: ["offset": size, "inode": inode]).write(to: legacy)
        try Self.append(#"{"message":"not sent yet","location":"a.rs:2:1"}"# + "\n", to: file)

        let recorder = Recorder()
        let forwarder = OwnerPanicForwarder(logs: [.file(file, source: .owner, kind: .panic)], stateFile: dir.appending(path: "state.json"),
                                            legacyStates: [file: legacy], sends: true, capture: { recorder.capture($0) })
        #expect(forwarder.forwardNew().isEmpty, "the first run keeps the earlier offset")
        let sent = forwarder.forwardNew()
        #expect(sent.map(\.fingerprint) == [["owner-panic", "a.rs:2:1"]])
    }

    @Test func aFloodSendsAtMostTheCapPerFile() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = Self.hangLog(dir)
        let file = log.directory.appending(path: "hangs-1.jsonl")
        try Self.append("", to: file)
        let recorder = Recorder()
        let forwarder = Self.forwarder([log], dir: dir, recorder: recorder)
        _ = forwarder.forwardNew()
        try Self.append(String(repeating: Self.fixtureLine(), count: OwnerPanicForwarder.maxEventsPerFile + 5), to: file)
        #expect(forwarder.forwardNew().count == OwnerPanicForwarder.maxEventsPerFile)
        #expect(forwarder.forwardNew().isEmpty, "the rest is marked read")
    }

    @Test func theListCoversEveryShippedRole() {
        let roots = RustDiagnosticsLog.Roots.app(stateRoot: URL(filePath: "/state"), session: "main", acpmuxHome: URL(filePath: "/acpmux"),
                                                 bundleID: "com.cmuxterm.app.next", uid: 501)
        let logs = RustDiagnosticsLog.all(roots)
        let roles: [RustPanicSource] = [.owner, .acpmux, .terminalHost, .holder, .agentHost, .appHost, .browserHost, .mcp,
                                        .cloud, .optchatChief, .diffSidecar, .serverHelper]
        for role in roles {
            #expect(logs.contains { $0.source == role && $0.kind == .panic }, "\(role.process) panics")
            #expect(logs.contains { $0.source == role && $0.kind == .hang }, "\(role.process) hangs")
        }
        // Each process's hang file is named by its pid only: no two roles share a hang folder.
        let hangFolders = logs.filter { $0.kind == .hang }.map(\.directory)
        #expect(Set(hangFolders).count == hangFolders.count)
        // The holder's 0700 socket folder and root's log folder are never made by the app.
        #expect(logs.filter { [RustPanicSource.holder, .serverHelper].contains($0.source) }.allSatisfy { !$0.createsDirectory })
        #expect(logs.contains { $0.name == .exact("owner-panics-main.jsonl") && $0.directory.path == "/state" })
        #expect(RustDiagnosticsLog.Name.pattern(prefix: "hangs-", suffix: ".jsonl").matches("hangs-42.jsonl"))
        #expect(!RustDiagnosticsLog.Name.pattern(prefix: "hangs-", suffix: ".jsonl").matches("hangs-42.jsonl.sent"))
    }
}
