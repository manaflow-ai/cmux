import Foundation
import Testing
@testable import CmuxNextCrashReporting

/// ``CrashForwarders/start()`` starts each forwarder on its own queue, so a panic the last run left is sent there,
/// and acpmux is found once, on the calling thread. A helper crash forwarder that waits for its release (the
/// hang-reports controller's first decision) does its pass only at whichever of the start and the release comes last.
@Suite(.timeLimit(.minutes(1))) struct CrashForwardersTests {
    @Test func aSystemForwarderThatWaitsForItsReleaseDoesNoPassBeforeIt() async throws {
        let dir = try CrashForwardersScratch()
        defer { dir.remove() }
        let (seen, report) = AsyncStream.makeStream(of: CrashForwardersReport.self)
        let forwarders = dir.forwarders(systemWaitsForRelease: true,
                                        report: { report.yield(CrashForwardersReport(value: $0)) })
        forwarders.start()
        var reports = seen.makeAsyncIterator()
        let first = try #require(await reports.next())
        let second = try #require(await reports.next())
        #expect(Set([first.value, second.value]) == ["acpmux.made", "owner: boom"])
        #expect(!FileManager.default.fileExists(atPath: dir.systemState.path), "the helper forwarder ran before its release")
        forwarders.releaseSystem()
        await dir.waitForSystemState()
    }

    @Test func aSystemForwarderReleasedBeforeTheStartDoesItsPassThen() async throws {
        let dir = try CrashForwardersScratch()
        defer { dir.remove() }
        let forwarders = dir.forwarders(systemWaitsForRelease: true)
        forwarders.releaseSystem()
        #expect(!FileManager.default.fileExists(atPath: dir.systemState.path), "the release alone started the helper forwarder")
        forwarders.start()
        await dir.waitForSystemState()
    }

    @Test func startSendsThePreviousRunsPanicOnTheForwardersQueue() async throws {
        let dir = try CrashForwardersScratch()
        defer { dir.remove() }
        let (seen, report) = AsyncStream.makeStream(of: CrashForwardersReport.self)
        let forwarders = dir.forwarders(report: { report.yield(CrashForwardersReport(value: $0)) })
        forwarders.start()
        var reports = seen.makeAsyncIterator()
        // The owner's queue and the calling thread both report, in no set order.
        let first = try #require(await reports.next())
        let second = try #require(await reports.next())
        #expect(Set([first.value, second.value]) == ["acpmux.made", "owner: boom"])
        let byValue = Dictionary([first, second].map { ($0.value, $0.thread) }, uniquingKeysWith: { kept, _ in kept })
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

/// A scratch folder with an owner panic log that a previous run read to its end and then appended one panic to.
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
    }

    var log: URL { root.appending(path: "owner-panics-s.jsonl") }
    var ownerState: URL { root.appending(path: "owner-state.json") }
    var systemState: URL { root.appending(path: "system-state.json") }

    /// Returns once the helper crash forwarder's first pass wrote its state (the suite's time limit bounds the wait).
    func waitForSystemState() async {
        while !FileManager.default.fileExists(atPath: systemState.path) { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// The forwarders over this folder; each sent panic and the acpmux search go to `report`.
    func forwarders(systemWaitsForRelease: Bool = false,
                    report record: @escaping @Sendable (String) -> Void = { _ in }) -> CrashForwarders {
        let system = SystemCrashForwarder(directory: root.appending(path: "DiagnosticReports", directoryHint: .isDirectory),
                                          stateFile: systemState, bundlePath: root.path,
                                          mainExecutable: nil, hostExeRoot: nil, ownRustBinaries: [], artifacts: nil,
                                          capture: { _, _ in record("system") })
        let owner = OwnerPanicForwarder(log: log, stateFile: ownerState, sends: true,
                                        capture: { event in record("owner: \(event.exceptions?.first?.value ?? "")") })
        return CrashForwarders(system: system, ownerPanics: owner, systemWaitsForRelease: systemWaitsForRelease) {
            record("acpmux.made")
            return nil
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
