import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextCrashReporting

/// ``CrashForwarders/run()`` does the forwarders' first pass on the calling thread (the launch's
/// best-effort files lane), so a panic the last run left is sent when it returns, and acpmux is found once, there.
@Suite struct CrashForwardersTests {
    @Test func runSendsThePreviousRunsPanicOnTheCallingThreadAndFindsAcpmuxOnce() throws {
        let dir = try CrashForwardersScratch()
        defer { dir.remove() }
        let sent = CrashForwardersSent()
        let forwarders = dir.forwarders(sent: sent)
        #expect(sent.values.isEmpty, "making the forwarders read or sent something")
        forwarders.run()
        #expect(sent.values == ["owner: boom", "acpmux.made"])
        #expect(forwarders.acpmuxPanics == nil, "this test's acpmux maker finds no acpmux")
    }

    /// A helper crash forwarder that waits for its release (the hang-reports controller's first
    /// decision) does no pass in ``CrashForwarders/run()`` before it; the other forwarders do theirs.
    @Test func aSystemForwarderThatWaitsForItsReleaseDoesNoPassBeforeIt() throws {
        let dir = try CrashForwardersScratch()
        defer { dir.remove() }
        let sent = CrashForwardersSent()
        let forwarders = dir.forwarders(sent: sent, systemWaitsForRelease: true)
        forwarders.run()
        #expect(sent.values == ["owner: boom", "acpmux.made"])
        #expect(!FileManager.default.fileExists(atPath: dir.systemState.path), "the helper forwarder ran before its release")
    }

    @Test func aSystemForwarderReleasedBeforeTheRunDoesItsPassInIt() throws {
        let dir = try CrashForwardersScratch()
        defer { dir.remove() }
        let forwarders = dir.forwarders(sent: nil, systemWaitsForRelease: true)
        forwarders.releaseSystem()
        #expect(!FileManager.default.fileExists(atPath: dir.systemState.path), "the release alone started the helper forwarder")
        forwarders.run()
        #expect(FileManager.default.fileExists(atPath: dir.systemState.path), "the run skipped the released helper forwarder")
    }

    @Test func startSendsThePreviousRunsPanicOnTheForwardersQueue() async throws {
        let dir = try CrashForwardersScratch()
        defer { dir.remove() }
        let (seen, report) = AsyncStream.makeStream(of: CrashForwardersReport.self)
        let forwarders = dir.forwarders(sent: nil, report: { report.yield(CrashForwardersReport(value: $0)) })
        forwarders.start()
        var reports = seen.makeAsyncIterator()
        // The owner's queue and the calling thread both report, in no set order.
        let first = try #require(await reports.next())
        let second = try #require(await reports.next())
        #expect(Set([first.value, second.value]) == ["acpmux.made", "owner: boom"])
        let byValue = Dictionary([first, second].map { ($0.value, $0.thread) }, uniquingKeysWith: { kept, _ in kept })
        // start() finds acpmux on the calling thread, as the launch did before the feature, and the
        // owner's panic goes out on the forwarder's own queue, so on another thread.
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

    /// The forwarders over this folder; each sent panic and the acpmux search go to `sent` or `report`.
    func forwarders(sent: CrashForwardersSent?, systemWaitsForRelease: Bool = false,
                    report: @escaping @Sendable (String) -> Void = { _ in }) -> CrashForwarders {
        let record: @Sendable (String) -> Void = { value in
            sent?.append(value)
            report(value)
        }
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

/// What the forwarders sent, in order, from any thread.
private final class CrashForwardersSent: Sendable {
    private let state = Mutex<[String]>([])

    var values: [String] { state.withLock { $0 } }

    func append(_ value: String) { state.withLock { $0.append(value) } }
}
