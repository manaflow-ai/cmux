import Foundation
import Sentry
import Testing
import CmuxNextCompat
@testable import CmuxNextCrashReporting

/// p10-stability-150: acpmux and owner panics, their hang logs (holder-link and holder-loop scopes
/// included) and the in-app FFI panic ring reach Sentry under the person's consent, and no event
/// carries a path or a URL.
@Suite struct RustLogForwardTests {
    private static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "rust-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func append(_ fields: [String: Any], to url: URL) throws {
        var data = try JSONSerialization.data(withJSONObject: fields)
        data.append(UInt8(ascii: "\n"))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Every text of `event` that reaches Sentry, joined.
    private static func texts(_ event: Event) -> String {
        var parts = [event.message?.formatted ?? ""]
        parts += event.exceptions?.map(\.value) ?? []
        parts += event.fingerprint ?? []
        parts += event.tags.map { Array($0.values) } ?? []
        parts += (event.extra ?? [:]).values.map { String(describing: $0) }
        return parts.joined(separator: "\n")
    }

    @Test func anAcpmuxPanicIsOneForwardedEventWithNoPaths() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = RustPanicSource.acpmuxLog(acpmuxHome: dir)
        try Data().write(to: log)
        let forwarder = OwnerPanicForwarder(log: log, stateFile: dir.appending(path: "state.json"), sends: true,
                                            source: .acpmux, capture: { _ in })
        #expect(forwarder.forwardNew().isEmpty)
        try Self.append([
            "process": "acpmux", "pid": 4242, "version": "0.9.1", "os": "macos", "arch": "aarch64",
            "message": "open /Users/maya/Library/Application Support/acpmux/chats/x.json failed: see file:///Users/maya/a",
            "location": "/Users/maya/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/tokio-1.53.1/src/fs.rs:12:5",
            "thread": "tokio-rt-worker", "test": false,
            "backtrace": "  3: acpmux::hub::load\n             at /Users/maya/src/cmux/cmux-tui/crates/acpmux/src/hub/mod.rs:941:5",
        ], to: log)

        let sent = forwarder.forwardNew()
        try #require(sent.count == 1)
        let text = Self.texts(sent[0])
        #expect(!text.contains("/Users"))
        #expect(!text.contains("maya"))
        #expect(!text.contains("file://"))
        #expect(sent[0].fingerprint == ["acpmux-panic", "<cargo>/tokio-1.53.1/src/fs.rs:12:5"])
        #expect(sent[0].exceptions?.first?.value == "open <path> failed: see <url>")
        #expect(sent[0].extra?["backtrace"] as? String
            == "  3: acpmux::hub::load\n             at acpmux/src/hub/mod.rs:941:5")
        #expect(sent[0].tags?["tui_os"] == "macos")
        #expect(forwarder.forwardNew().isEmpty)
    }

    @Test func aHangLineIsOneWarningAndLabLinesAreNotSent() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = OwnerPanicForwarder.hangLog(stateRoot: dir, session: "main")
        #expect(log.lastPathComponent == "owner-hangs-main.jsonl")
        try Data().write(to: log)
        let forwarder = OwnerPanicForwarder(log: log, stateFile: dir.appending(path: "state.json"), sends: true,
                                            source: .ownerHangs, capture: { _ in })
        #expect(forwarder.forwardNew().isEmpty)
        try Self.append(["kind": "slow_poll", "poll_ms": 3, "spawned_at": "/Users/maya/x.rs:1:1"], to: log)
        try Self.append(["event": "hang", "scope": "holder-link", "method": "output", "test": true], to: log)
        try Self.append([
            "event": "hang", "scope": "holder-link", "method": "output", "hang_ms": 1000, "busy_ms": 1450,
            "stack": [["image": "/Applications/cmux.app/Contents/Resources/bin/cmux-tui", "image_id": "ABC",
                       "offset": 4096, "symbol": "_ZN4core3foo"]],
            "stack_truncated": false, "session": "maya-secret", "os": "macos",
        ], to: log)

        let sent = forwarder.forwardNew()
        try #require(sent.count == 1)
        let event = sent[0]
        #expect(event.level == .warning)
        #expect(event.exceptions?.first?.type == "RustHang")
        #expect(event.fingerprint == ["owner-hang", "holder-link", "output"])
        #expect(event.tags?["crash_source"] == "owner_hang_log")
        #expect(event.tags?["hang_scope"] == "holder-link")
        #expect(event.extra?["stack"] as? [String] == ["cmux-tui+0x1000 _ZN4core3foo"])
        let text = Self.texts(event)
        #expect(!text.contains("/Applications"))
        #expect(!text.contains("maya-secret"))
    }

    @Test func linesFromATimeReportsWereOffAreNeverSent() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = RustPanicSource.acpmuxHangLog(acpmuxHome: dir)
        try Data().write(to: log)
        let state = dir.appending(path: "state.json")
        let off = OwnerPanicForwarder(log: log, stateFile: state, sends: false, source: .acpmuxHangs,
                                      capture: { _ in Issue.record("sent with reports off") })
        _ = off.forwardNew()
        try Self.append(["event": "hang", "scope": "mux-conn", "method": "list", "busy_ms": 2100], to: log)
        #expect(off.forwardNew().isEmpty)
        let on = OwnerPanicForwarder(log: log, stateFile: state, sends: true, source: .acpmuxHangs, capture: { _ in })
        #expect(on.forwardNew().isEmpty)
    }

    /// The Rust writers create their logs at the first record: on a fresh home that first record
    /// is the one Sentry must get.
    @Test func aLogCreatedAfterTheFirstRunIsReadFromItsFirstLine() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = RustPanicSource.acpmuxLog(acpmuxHome: dir)
        let forwarder = OwnerPanicForwarder(log: log, stateFile: dir.appending(path: "state.json"), sends: true,
                                            source: .acpmux, capture: { _ in })
        #expect(forwarder.forwardNew().isEmpty)
        #expect(forwarder.forwardNew().isEmpty)
        try Data().write(to: log)
        try Self.append(["process": "acpmux", "role": "agent-host", "message": "first", "location": "a.rs:1:1",
                         "thread": "w"], to: log)

        let sent = forwarder.forwardNew()
        try #require(sent.count == 1)
        #expect(sent[0].exceptions?.first?.value == "first")
        #expect(sent[0].tags?["process_role"] == "agent-host")
        #expect(forwarder.forwardNew().isEmpty)
    }

    @Test func identicalHangsAreOneEventADayUnderADailyCap() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = OwnerPanicForwarder.hangLog(stateRoot: dir, session: "main")
        try Data().write(to: log)
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let forwarder = OwnerPanicForwarder(log: log, stateFile: dir.appending(path: "state.json"), sends: true,
                                            source: .ownerHangs, capture: { _ in }, now: { clock.now() })
        _ = forwarder.forwardNew()
        let hang: [String: Any] = ["event": "hang", "scope": "holder-loop", "method": "poll", "busy_ms": 140]
        for _ in 0..<50 { try Self.append(hang, to: log) }
        #expect(forwarder.forwardNew().count == 1)
        try Self.append(hang, to: log)
        #expect(forwarder.forwardNew().isEmpty, "the same hang again that day")

        for index in 0..<(OwnerPanicForwarder.maxHangEventsPerDay + 5) {
            try Self.append(["event": "hang", "scope": "mux-conn", "method": "m\(index)", "busy_ms": 600], to: log)
        }
        #expect(forwarder.forwardNew().count == OwnerPanicForwarder.maxHangEventsPerDay - 1)

        clock.advance(by: 86_400)
        try Self.append(hang, to: log)
        try Self.append(hang, to: log)
        #expect(forwarder.forwardNew().count == 1, "a new day sends it once more")
    }

    @Test func theHolderLogIsInTheSessionsTerminalHostRoot() {
        let sessions = URL(filePath: "/state/sessions", directoryHint: .isDirectory)
        // cmux-tui-core diagnostics::holder_panic_log_path pins the same name for session "main".
        #expect(RustPanicSource.holderLog(sessionsDirectory: sessions, session: "main").path
            == "/state/sessions/terminal-hosts-1f5962a2ce9803c8/holder-panics.jsonl")
        #expect(RustPanicSource.holder.fingerprintPrefix == "holder-panic")
    }

    @Test func theScrubberKeepsCrateRelativeSourcesAndDropsEverythingElse() {
        let scrubber = RustLogScrubber()
        #expect(scrubber.scrub("crates/acpmux/src/hub/mod.rs:941:5") == "crates/acpmux/src/hub/mod.rs:941:5")
        #expect(scrubber.scrub("at /rustc/17067e9a/library/core/src/ops.rs:250:5")
            == "at /rustc/17067e9a/library/core/src/ops.rs:250:5")
        #expect(scrubber.scrub("no file ~/notes/plan.md.") == "no file <path>.")
        #expect(scrubber.scrub("bad path=\"/private/var/folders/x/T/ab\"") == "bad path=\"<path>\"")
        #expect(scrubber.scrub("a / b") == "a / b")
        #expect(scrubber.scrub("at /home/maya/.cargo/git/checkouts/ghostty-1a2b/9f8e7d6/src/lib.rs:3")
            == "at <cargo>/ghostty-1a2b/9f8e7d6/src/lib.rs:3")
        #expect(scrubber.scrub("at /opt/build/main.rs:7") == "at <path>/main.rs:7")
        // A folder before `src` outside a known build root may be the account or a private project.
        #expect(scrubber.scrub("at /Users/maya/src/x.rs:1") == "at <path>/x.rs:1")
        #expect(scrubber.scrub("at /Users/maya/Clients/acme/src/main.rs:1") == "at <path>/main.rs:1")
        #expect(scrubber.scrub("at /Users/maya/crates/acme/src/main.rs:1") == "at <path>/main.rs:1")
        #expect(scrubber.scrub("at /Users/runner/work/cmux/cmux-tui/crates/cmux-holder/src/lib.rs:9:3")
            == "at cmux-holder/src/lib.rs:9:3")
        #expect(scrubber.scrub("GET https://api.example.com/v1/x?token=abc failed")
            == "GET <url> failed")
        #expect(scrubber.scrub("index 3 out of range for slice of length 2")
            == "index 3 out of range for slice of length 2")
        #expect(scrubber.imageName("/Users/maya/Applications/cmux.app/Contents/MacOS/cmux") == "cmux")
    }

    @Test func theFFIRingIsDrainedOnceWithItsLostCountAndNoPaths() {
        let ring = RecordedRing([
            FFIPanicRecord(sequence: 1, export: "cmux_rd_session_open", message: "open /Users/maya/x failed",
                           truncated: false),
            FFIPanicRecord(sequence: 4, export: "cmux_motion_step", message: "index out of bounds", truncated: true),
        ])
        var drain = FFIPanicDrain(sends: true, take: { ring.take() }, capture: { _ in })
        let sent = drain.drain()
        #expect(sent.count == 2)
        #expect(sent.first?.fingerprint == ["ffi-panic", "cmux_rd_session_open"])
        #expect(sent.first?.exceptions?.first?.value == "open <path> failed")
        #expect(sent.first?.exceptions?.first?.mechanism?.handled?.boolValue == true)
        #expect(sent.last?.extra?["lost_before"] as? UInt64 == 2)
        #expect(sent.last?.tags?["crash_source"] == "ffi_panic_ring")
        #expect(drain.drain().isEmpty)

        let offRing = RecordedRing([FFIPanicRecord(sequence: 1, export: "e", message: "m", truncated: false)])
        var off = FFIPanicDrain(sends: false, take: { offRing.take() },
                                capture: { _ in Issue.record("sent with reports off") })
        #expect(off.drain().isEmpty)
        #expect(offRing.take() == nil, "a drain with reports off still empties the ring")
    }
}

/// A stand-in for cmux-ffi-guard's ring: each take removes the oldest record.
private final class RecordedRing: Sendable {
    private let records: Mutex<[FFIPanicRecord]>

    init(_ records: [FFIPanicRecord]) {
        self.records = Mutex(records)
    }

    func take() -> FFIPanicRecord? {
        records.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}

/// A clock a test moves by hand.
private final class TestClock: Sendable {
    private let date: Mutex<Date>

    init(_ date: Date) {
        self.date = Mutex(date)
    }

    func now() -> Date {
        date.withLock { $0 }
    }

    func advance(by interval: TimeInterval) {
        date.withLock { $0 += interval }
    }
}
