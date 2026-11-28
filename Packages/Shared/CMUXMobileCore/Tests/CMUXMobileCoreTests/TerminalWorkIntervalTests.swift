import Foundation
import Testing
@testable import CMUXMobileCore

struct TerminalWorkIntervalTests {
    @Test func entryIsAvailableBeforeTheOperationReturns() async {
        let log = DiagnosticLog(capacity: 8)
        let id = UUID()
        let context = TerminalWorkContext(
            transition: .restore, population: .window, workspaceCount: 12, surfaceCount: 80
        )
        let interval = log.beginTerminalWork(
            .resizePublication, context: context, operationID: id, at: 1_000_000, onMainThread: true
        )
        let entered = await waitForEvents(log, count: 1)
        #expect(entered.map(\.code) == [.terminalWorkStarted])
        #expect(entered.first?.terminalWork?.context == context)
        #expect(entered.first?.terminalWork?.operationID == id)

        interval.end(at: 252_000_000)
        let completed = await waitForEvents(log, count: 2)
        #expect(completed.last?.code == .terminalWorkFinished)
        #expect(completed.last?.ms == 251)
        #expect(completed.last?.terminalWork == entered.first?.terminalWork)
    }

    @Test func countersAndDurationsAreBounded() async throws {
        let context = TerminalWorkContext(workspaceCount: -20, surfaceCount: Int.max)
        #expect(context.workspaceCount == 0)
        #expect(context.surfaceCount == Int(UInt16.max))
        let log = DiagnosticLog(capacity: 8)
        let interval = log.beginTerminalWork(.renderGridReplay, context: context, at: 1)
        interval.end(at: UInt64.max)
        let events = await waitForEvents(log, count: 2)
        #expect(events.last?.ms == UInt32.max)
        let encoded = try JSONEncoder().encode(events)
        #expect(try JSONDecoder().decode([DiagnosticEvent].self, from: encoded) == events)
    }

    @Test func oldEventsStillDecodeWithoutTerminalMetadata() throws {
        let data = Data(#"{"code":1,"tNanos":10}"#.utf8)
        let event = try JSONDecoder().decode(DiagnosticEvent.self, from: data)
        #expect(event.terminalWork == nil)
        #expect(event.code == .connect)
    }

    private func waitForEvents(_ log: DiagnosticLog, count: Int) async -> [DiagnosticEvent] {
        for _ in 0..<100_000 {
            if await log.processedCount() >= count { return await log.snapshot().events }
            await Task.yield()
        }
        Issue.record("Diagnostic ingress did not drain")
        return await log.snapshot().events
    }
}
