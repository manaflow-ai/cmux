import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextCrashReporting

/// p08-startup-078: ``CrashForwarders/run()`` does the forwarders' first pass on the calling thread (the launch's
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

    @Test func startSendsThePreviousRunsPanicOnTheForwardersQueue() async throws {
        let dir = try CrashForwardersScratch()
        defer { dir.remove() }
        let (seen, report) = AsyncStream.makeStream(of: String.self)
        let forwarders = dir.forwarders(sent: nil, report: { report.yield($0) })
        forwarders.start()
        var reports = seen.makeAsyncIterator()
        // start() finds acpmux on the calling thread, as the launch did before the feature.
        let first = await reports.next()
        #expect(first == "acpmux.made")
        let second = await reports.next()
        #expect(second == "owner: boom")
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

    /// The forwarders over this folder; each sent panic and the acpmux search go to `sent` or `report`.
    func forwarders(sent: CrashForwardersSent?, report: @escaping @Sendable (String) -> Void = { _ in }) -> CrashForwarders {
        let record: @Sendable (String) -> Void = { value in
            sent?.append(value)
            report(value)
        }
        let system = SystemCrashForwarder(directory: root.appending(path: "DiagnosticReports", directoryHint: .isDirectory),
                                          stateFile: root.appending(path: "system-state.json"), bundlePath: root.path,
                                          mainExecutable: nil, capture: { _ in record("system") })
        let owner = OwnerPanicForwarder(log: log, stateFile: ownerState, sends: true,
                                        capture: { event in record("owner: \(event.exceptions?.first?.value ?? "")") })
        return CrashForwarders(system: system, ownerPanics: owner) {
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
