import CmuxNextCompat
@testable import CmuxNextTrace
@testable import CmuxNextWakeups
import Foundation
import Testing

/// The typing probe obeys the keystroke-timing gate: while secure input is on it writes no
/// CSV row and no `key.flow` hop, and gives the daemon no flow id, so no process writes a `key.echo` hop for the key.
@Suite(.serialized) struct TypingProbeKeyTimingGateTests {
    /// The ring records a test runtime wrote while no ring is attached.
    private final class RecordCount: Sendable {
        private let count = Mutex(0)

        func add() { count.withLock { $0 += 1 } }

        var value: Int { count.withLock { $0 } }
    }

    @Test("With the gate closed, a key opens no sample, no flow and no hop")
    func aClosedGateSamplesNothing() throws {
        let count = RecordCount()
        let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { _ in count.add() })
        runtime.setCategories(.all)
        let csv = FileManager.default.temporaryDirectory.appendingPathComponent("typing-probe-gate-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: csv) }
        let probe = TypingLatencyProbe(path: csv.path, trace: runtime)
        probe.startFlows()
        let surface = probe.makeSurfaceKey()

        probe.keyDown(eventTimestamp: 0)
        probe.keyReachedTerminal(surface)
        probe.inputWritten(on: surface)
        #expect(probe.openFlow != nil)
        #expect(count.value > 0, "the open gate records the press's first hop")

        runtime.setKeyTimingSuppressed(true, by: .secureEventInput)
        #expect(probe.openFlow == nil, "the daemon gets no flow id for the press that was open")
        let before = count.value
        probe.keyDown(eventTimestamp: 0)
        for mark in TypingLatencyProbe.Mark.allCases { probe.mark(mark) }
        probe.keyReachedTerminal(surface)
        probe.inputWritten(on: surface)
        probe.outputDecoded(flow: nil)
        probe.mark(.contents, surface: surface)
        probe.closeAtCommit()
        #expect(probe.openFlow == nil)
        #expect(count.value == before)
        probe.flush()
        let rows = try String(contentsOf: csv, encoding: .utf8).split(separator: "\n")
        #expect(rows.count == 1, "the header only: the open press is dropped unwritten and none opens")

        runtime.setKeyTimingSuppressed(false, by: .secureEventInput)
        probe.keyDown(eventTimestamp: 0)
        probe.keyReachedTerminal(surface)
        probe.inputWritten(on: surface)
        #expect(probe.openFlow != nil)
    }
}
