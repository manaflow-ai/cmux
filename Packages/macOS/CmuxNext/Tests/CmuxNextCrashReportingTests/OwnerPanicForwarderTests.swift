import CmuxNextCompat
import CmuxNextTrace
import Foundation
import Sentry
import Testing
@testable import CmuxNextCrashReporting

/// Every shipped Rust role's panic and hang logs reach Sentry through one forwarder. A hang
/// line (cmux-hang-watch `hangs-<pid>.jsonl`, schema 1) is an event whose crashed thread carries the hung stack
/// (`instruction_addr` = image address + offset) and whose debug_meta lists every image UUID; each line is sent
/// once across restarts, and nothing is sent while telemetry is off.
@Suite struct OwnerPanicForwarderTests {
    /// Records what the forwarder sends, and wakes a test waiting for a count.
    final class Recorder: Sendable {
        /// One hang entry handed on: the thread it names and the process that wrote it.
        struct Entry: Sendable, Equatable {
            var thread: String
            var source: RustPanicSource
        }

        private struct Wait {
            let sent: Int
            let hangs: Int
            let continuation: CheckedContinuation<Void, Never>
        }

        private struct Seen {
            var sent = 0
            var hangs: [Entry] = []
            var waits: [Wait] = []
        }

        private let seen = Mutex(Seen())

        /// How many events were captured.
        var sent: Int { seen.withLock { $0.sent } }
        var hangEntries: [Entry] { seen.withLock { $0.hangs } }

        func capture(_: Event) { record { $0.sent += 1 } }
        func hang(_ record: RustHangRecord, _ source: RustPanicSource) {
            self.record { $0.hangs.append(Entry(thread: record.thread, source: source)) }
        }

        /// Returns once at least `sent` events were captured and `hangs` entries handed on (the suite's time limit
        /// bounds the wait).
        func waitUntil(sent: Int = 0, hangs: Int = 0) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let reached = seen.withLock { seen -> Bool in
                    guard seen.sent < sent || seen.hangs.count < hangs else { return true }
                    seen.waits.append(Wait(sent: sent, hangs: hangs, continuation: continuation))
                    return false
                }
                if reached { continuation.resume() }
            }
        }

        private func record(_ change: (inout Seen) -> Void) {
            let ready = seen.withLock { seen -> [CheckedContinuation<Void, Never>] in
                change(&seen)
                let sent = seen.sent, hangs = seen.hangs.count
                let ready = seen.waits.filter { sent >= $0.sent && hangs >= $0.hangs }.map(\.continuation)
                seen.waits.removeAll { sent >= $0.sent && hangs >= $0.hangs }
                return ready
            }
            for continuation in ready { continuation.resume() }
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

    static let hangs = RustDiagnosticsLog.Name.pattern(prefix: "hangs-", suffix: ".jsonl")

    static func hangLog(_ dir: URL, source: RustPanicSource = .owner) -> RustDiagnosticsLog {
        RustDiagnosticsLog(directory: dir.appending(path: "trace"), name: hangs, source: source, kind: .hang)
    }

    static func forwarder(_ logs: [RustDiagnosticsLog], dir: URL, sends: Bool = true, recorder: Recorder,
                          attached: Bool = true) -> OwnerPanicForwarder {
        let entries: OwnerPanicForwarder.HangEntries = { recorder.hang($0, $1) }
        return OwnerPanicForwarder(logs: logs, stateFile: dir.appending(path: "state.json"), sends: sends,
                                   hangEntries: attached ? entries : nil, capture: { recorder.capture($0) })
    }

    /// The hang log of `logs` that holds `file`, by the log's folder rule.
    static func hangLog(holding file: URL, in logs: [RustDiagnosticsLog]) -> RustDiagnosticsLog? {
        let folder = file.deletingLastPathComponent()
        return logs.first { log in
            guard log.kind == .hang, log.name.matches(file.lastPathComponent) else { return false }
            guard let perProcess = log.perProcessFolders else { return folder.path == log.directory.path }
            return folder.deletingLastPathComponent().path == log.directory.path && perProcess.matches(folder.lastPathComponent)
        }
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

    /// Each hang folder is the one its writer passes `cmux_hang_watch::init` (which appends `hangs-<pid>.jsonl` there),
    /// built here from that writer's rule.
    @Test func theListCoversEveryShippedRole() throws {
        let home = URL(filePath: "/Users/u", directoryHint: .isDirectory)
        let sessions = URL(filePath: "/state/sessions", directoryHint: .isDirectory)
        let roots = RustDiagnosticsLog.Roots.app(sessionsDirectory: sessions, session: "main", acpmuxHome: URL(filePath: "/acpmux"),
                                                 bundleID: "com.cmuxterm.app.next", uid: 501, home: home)
        let logs = RustDiagnosticsLog.all(roots)
        #expect(roots.stateRoot.path == "/state")

        // acpmux `daemon::hang_watch::init(&home())`: `$ACPMUX_HOME/hangs-<pid>.jsonl`, beside its panic log.
        let acpmux = try #require(Self.hangLog(holding: URL(filePath: "/acpmux/hangs-41.jsonl"), in: logs))
        #expect(acpmux.source == .acpmux)
        // cmux-holder `run`: `socket.with_extension("trace")`, the socket `/tmp/cmux-hd-<uid>/<16 hex>.sock`.
        let socket = URL(filePath: "/tmp/cmux-hd-501/0123456789abcdef.sock")
        let holderFolder = socket.deletingPathExtension().appendingPathExtension("trace")
        let holder = try #require(Self.hangLog(holding: holderFolder.appending(path: "hangs-42.jsonl"), in: logs))
        #expect(holder.source == .holder)
        #expect(!holder.createsDirectory, "the holder refuses a socket folder that is not its own 0700 one")
        // The terminal host: `host_trace_dir(record)` = `trace` beside its record, the record in
        // `terminal_host_root(sessions, session)` = `<sessions>/terminal-hosts-<stable_token(session)>`.
        #expect(RustDiagnosticsLog.Roots.stableToken("main") == "1f5962a2ce9803c8", "cmux-tui-core codec::stable_token")
        let record = sessions.appending(path: "terminal-hosts-1f5962a2ce9803c8").appending(path: "00ff.json")
        let host = try #require(Self.hangLog(holding: record.deletingLastPathComponent().appending(path: "trace/hangs-43.jsonl"), in: logs))
        #expect(host.source == .terminalHost)
        // Task 095: every process but the holder writes into the app's trace folder; the black box names the role.
        let trace = try #require(Self.hangLog(holding: home.appending(path: "Library/Logs/com.cmuxterm.app.next/trace/hangs-44.jsonl"),
                                              in: logs))
        #expect(trace.namesProcessByBlackBox)
        #expect(trace.source == .owner)

        let roles: [RustPanicSource] = [.owner, .acpmux, .terminalHost, .holder, .agentHost, .appHost, .browserHost, .mcp,
                                        .cloud, .optchatChief, .diffSidecar, .serverHelper]
        for role in roles {
            #expect(logs.contains { $0.source == role && $0.kind == .panic }, "\(role.process) panics")
        }
        // The holder's 0700 socket folder, the daemon's host folder and root's log folder are never made by the app.
        #expect(logs.filter { [RustPanicSource.holder, .serverHelper].contains($0.source) }.allSatisfy { !$0.createsDirectory })
        #expect(!host.createsDirectory, "the daemon makes its hosts' folder")
        #expect(logs.contains { $0.name == .exact("owner-panics-main.jsonl") && $0.directory.path == "/state" })
        #expect(RustDiagnosticsLog.Name.pattern(prefix: "hangs-", suffix: ".jsonl").matches("hangs-42.jsonl"))
        #expect(!RustDiagnosticsLog.Name.pattern(prefix: "hangs-", suffix: ".jsonl").matches("hangs-42.jsonl.sent"))
    }

    /// The trace folder holds several roles' `hangs-<pid>.jsonl`: each line names the process of its pid's black box.
    @Test func aSharedFolderNamesEachProcessByItsBlackBox() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let trace = RustDiagnosticsLog(directory: dir.appending(path: "trace"), name: Self.hangs, source: .owner, kind: .hang,
                                       namesProcessByBlackBox: true)
        let recorder = Recorder()
        let forwarder = Self.forwarder([trace], dir: dir, recorder: recorder)
        #expect(forwarder.forwardNew().isEmpty)
        try Self.append("", to: trace.directory.appending(path: TraceRingFile.fileName(role: .terminalHost, pid: 4242)))
        try Self.append(Self.fixtureLine(thread: "host-parser"), to: trace.directory.appending(path: "hangs-4242.jsonl"))
        try Self.append(Self.stacklessLine, to: trace.directory.appending(path: "hangs-9.jsonl"))

        let sent = forwarder.forwardNew()
        // Files are read in name order: hangs-4242 before hangs-9.
        #expect(sent.map { $0.tags?["process"] } == ["cmux-tui-host", "cmux-tui"])
        #expect(recorder.hangEntries == [Recorder.Entry(thread: "host-parser", source: .terminalHost),
                                         Recorder.Entry(thread: "holder-poll", source: .owner)])
    }

    /// kqueue's folder events miss an append to a file that exists: each log file has its own watch.
    @Test(.timeLimit(.minutes(1))) func aLineAppendedToALiveFileIsForwardedWithoutARead() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = Self.hangLog(dir)
        let file = log.directory.appending(path: "hangs-4242.jsonl")
        let recorder = Recorder()
        let forwarder = Self.forwarder([log], dir: dir, recorder: recorder)
        #expect(forwarder.forwardNew().isEmpty, "the first run")
        try Self.append(Self.fixtureLine(thread: "first"), to: file)

        // start() watches, then reads: the first line, made by the process's first hang.
        forwarder.start()
        await recorder.waitUntil(sent: 1)
        try Self.append(Self.fixtureLine(thread: "second"), to: file)
        await recorder.waitUntil(sent: 2, hangs: 2)
        #expect(recorder.hangEntries.map(\.thread) == ["first", "second"])
    }

    /// A holder's folder that is not there at launch (the first launch after a reboot) is watched from the nearest
    /// folder above it, and read once it appears.
    @Test(.timeLimit(.minutes(1))) func aFolderMadeAfterStartIsWatchedAndRead() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let holders = RustDiagnosticsLog(directory: dir.appending(path: "hd/sockets"), perProcessFolders: .pattern(prefix: "", suffix: ".trace"),
                                         name: Self.hangs, source: .holder, kind: .hang, createsDirectory: false)
        let recorder = Recorder()
        let forwarder = Self.forwarder([holders], dir: dir, recorder: recorder)
        #expect(forwarder.forwardNew().isEmpty, "the first run")
        forwarder.start()

        let folder = holders.directory.appending(path: "0123456789abcdef.trace")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.append(Self.stacklessLine, to: folder.appending(path: "hangs-9.jsonl"))
        await recorder.waitUntil(sent: 1, hangs: 1)
        #expect(recorder.hangEntries == [Recorder.Entry(thread: "holder-poll", source: .holder)])
    }

    /// The app attaches the hang-report sink after the forwarder's first read at launch: that backlog still reaches it.
    @Test(.timeLimit(.minutes(1))) func linesReadBeforeTheSinkAttachesReachIt() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = Self.hangLog(dir)
        let recorder = Recorder()
        let forwarder = Self.forwarder([log], dir: dir, recorder: recorder, attached: false)
        #expect(forwarder.forwardNew().isEmpty, "the first run")
        try Self.append(Self.fixtureLine(thread: "while-the-app-was-away"), to: log.directory.appending(path: "hangs-7.jsonl"))
        #expect(forwarder.forwardNew().count == 1)
        #expect(recorder.hangEntries.isEmpty)

        forwarder.setHangEntries { recorder.hang($0, $1) }
        await recorder.waitUntil(hangs: 1)
        #expect(recorder.hangEntries == [Recorder.Entry(thread: "while-the-app-was-away", source: .owner)])
    }

    /// The app makes its acpmux forwarder at the forwarders' first pass (finding acpmux reads the file system), after
    /// the hang-report sink may have attached to ``CrashForwarders``: acpmux's hang lines still reach that sink.
    @Test(.timeLimit(.minutes(1))) func theAcpmuxForwarderMadeAfterTheSinkAttachesHandsItsHangsOn() async throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = dir.appending(path: "acpmux", directoryHint: .isDirectory)
        let hangFile = home.appending(path: "hangs-7.jsonl")
        try Self.append("", to: hangFile)
        let acpmuxLogs = RustDiagnosticsLog.acpmux(home: home)
        let acpmuxState = dir.appending(path: "acpmux-state.json")
        // The previous run read the log to its end; this run's line comes after.
        _ = OwnerPanicForwarder(logs: acpmuxLogs, stateFile: acpmuxState, sends: true, capture: { _ in }).forwardNew()
        try Self.append(Self.fixtureLine(thread: "acpmux-request"), to: hangFile)
        let recorder = Recorder()
        let system = SystemCrashForwarder(directory: dir.appending(path: "DiagnosticReports", directoryHint: .isDirectory),
                                          stateFile: dir.appending(path: "system-state.json"), bundlePath: dir.path,
                                          mainExecutable: nil, hostExeRoot: nil, ownRustBinaries: [], artifacts: nil,
                                          capture: { _, _ in })
        let owner = Self.forwarder([Self.hangLog(dir)], dir: dir, recorder: recorder, attached: false)
        let forwarders = CrashForwarders(system: system, ownerPanics: owner) {
            OwnerPanicForwarder(logs: acpmuxLogs, stateFile: acpmuxState, sends: true, capture: { recorder.capture($0) })
        }
        forwarders.setHangEntries { recorder.hang($0, $1) }
        forwarders.run()
        await recorder.waitUntil(sent: 1, hangs: 1)
        #expect(recorder.hangEntries == [Recorder.Entry(thread: "acpmux-request", source: .acpmux)])
        #expect(forwarders.acpmuxPanics != nil)
    }
}
