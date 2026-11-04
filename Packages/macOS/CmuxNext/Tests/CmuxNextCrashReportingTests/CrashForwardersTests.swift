import Foundation
import Testing
@testable import CmuxNextCrashReporting

/// ``CrashForwarders/start()`` starts each forwarder on its own queue, so a panic and a helper crash report the last
/// run left are sent there, and acpmux is found once, on the calling thread. A helper crash forwarder that waits for
/// its release (the hang-reports controller's first decision) does its one pass at whichever of the start and the
/// release comes last. Each test waits on the forwarders' own sends (their capture callbacks) and reads the gate's
/// started-pass count (``CrashForwarders/systemPassesStarted``), never a timer.
@Suite(.timeLimit(.minutes(1))) struct CrashForwardersTests {
    @Test func aSystemForwarderThatWaitsForItsReleaseDoesNoPassBeforeIt() async throws {
        let dir = try CrashForwardersScratch()
        defer { dir.remove() }
        let (seen, report) = AsyncStream.makeStream(of: String.self)
        let forwarders = dir.forwarders(systemWaitsForRelease: true) { report.yield($0) }
        forwarders.start()
        var reports = seen.makeAsyncIterator()
        var before: Set<String> = []
        for _ in 0..<2 { before.insert(try #require(await reports.next())) }
        #expect(before == ["acpmux.made", "owner: boom"])
        #expect(forwarders.systemPassesStarted == 0, "the helper forwarder started before its release")
        forwarders.releaseSystem()
        #expect(forwarders.systemPassesStarted == 1)
        #expect(await reports.next() == "system")
        forwarders.releaseSystem()
        #expect(forwarders.systemPassesStarted == 1, "a second release started a second pass")
    }

    @Test func aSystemForwarderReleasedBeforeTheStartDoesItsPassWithTheOthers() async throws {
        let dir = try CrashForwardersScratch()
        defer { dir.remove() }
        let (seen, report) = AsyncStream.makeStream(of: String.self)
        let forwarders = dir.forwarders(systemWaitsForRelease: true) { report.yield($0) }
        forwarders.releaseSystem()
        #expect(forwarders.systemPassesStarted == 0, "the release alone started the helper forwarder")
        forwarders.start()
        #expect(forwarders.systemPassesStarted == 1)
        var reports = seen.makeAsyncIterator()
        var values: Set<String> = []
        for _ in 0..<3 { values.insert(try #require(await reports.next())) }
        #expect(values == ["acpmux.made", "owner: boom", "system"])
    }

    @Test func startSendsThePreviousRunsPanicOnTheForwardersQueue() async throws {
        let dir = try CrashForwardersScratch()
        defer { dir.remove() }
        let (seen, report) = AsyncStream.makeStream(of: CrashForwardersReport.self)
        let forwarders = dir.forwarders(report: { report.yield(CrashForwardersReport(value: $0)) })
        forwarders.start()
        var reports = seen.makeAsyncIterator()
        // The owner's queue, the helper forwarder's queue and the calling thread all report, in no set order.
        let first = try #require(await reports.next())
        let second = try #require(await reports.next())
        let third = try #require(await reports.next())
        #expect(Set([first.value, second.value, third.value]) == ["acpmux.made", "owner: boom", "system"])
        let byValue = Dictionary([first, second, third].map { ($0.value, $0.thread) }, uniquingKeysWith: { kept, _ in kept })
        // start() finds acpmux on the calling thread, and the owner's panic goes out on the forwarder's own
        // queue, so on another thread.
        #expect(byValue["acpmux.made"] != byValue["owner: boom"])
    }
}

/// One report and the thread it was made on.
private struct CrashForwardersReport: Sendable {
    let value: String
    let thread: ObjectIdentifier

    init(value: String) {
        self.value = value
        thread = ObjectIdentifier(Thread.current)
    }
}

/// A scratch folder with an owner panic log and a helper crash report folder that a previous run read to their end,
/// then one panic and one helper crash report written after it.
private struct CrashForwardersScratch {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "crash-forwarders-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: log)
        // The previous run's first read marks the log read; its panic comes after.
        _ = OwnerPanicForwarder(log: log, stateFile: ownerState, sends: true, capture: { _ in }).forwardNew()
        var line = try JSONSerialization.data(withJSONObject: ["message": "boom", "location": "a.rs:1:1", "thread": "w"])
        line.append(UInt8(ascii: "\n"))
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        // The previous run's first pass sets the watermark; the helper's crash report comes after.
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        _ = system { _ in }.forwardNew(now: Date(timeIntervalSince1970: 0))
        try SystemCrashReportTests.ips(path: SystemCrashReportTests.bundle + "/Contents/Resources/bin/cmux-tui")
            .write(to: reports.appending(path: "cmux-tui-2026-10-29-120000.ips"))
    }

    var log: URL { root.appending(path: "owner-panics-s.jsonl") }
    var ownerState: URL { root.appending(path: "owner-state.json") }
    var systemState: URL { root.appending(path: "system-state.json") }

    var reports: URL { root.appending(path: "DiagnosticReports", directoryHint: .isDirectory) }

    /// The helper crash forwarder over this folder, for a bundle at ``SystemCrashReportTests/bundle``.
    func system(_ record: @escaping @Sendable (String) -> Void) -> SystemCrashForwarder {
        SystemCrashForwarder(directory: reports, stateFile: systemState, bundlePath: SystemCrashReportTests.bundle,
                             mainExecutable: nil, hostExeRoot: nil, ownRustBinaries: [], artifacts: nil,
                             capture: { _, _ in record("system") })
    }

    /// The forwarders over this folder; each sent report and the acpmux search go to `report`.
    func forwarders(systemWaitsForRelease: Bool = false,
                    report record: @escaping @Sendable (String) -> Void = { _ in }) -> CrashForwarders {
        let system = system(record)
        let owner = OwnerPanicForwarder(log: log, stateFile: ownerState, sends: true,
                                        capture: { event in record("owner: \(event.exceptions?.first?.value ?? "")") })
        return CrashForwarders(system: system, ownerPanics: owner, systemWaitsForRelease: systemWaitsForRelease) {
            record("acpmux.made")
            return nil
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
