@testable import CmuxNextHangReports
import Foundation
import Testing

/// The service and the main-thread part: a schema 3 send carries
/// `active_seconds` and both histograms, each turn goes in one report only, the ledger moves on
/// only once a report is queued, and what is not sent survives a quit.
/// Run: `swift test --filter HangReportServiceTests`.
extension HangReportServiceTests {
    typealias Inputs = MainThreadReportLedgerTests.Inputs

    private static let second = MainThreadReportLedgerTests.second

    private func decoded(_ body: Data) throws -> HangReport { try JSONDecoder().decode(HangReport.self, from: body) }

    @Test func aSchemaThreeSendCarriesActiveSecondsAndBothMainThreadHistograms() async throws {
        let inputs = Inputs()
        let ledger = inputs.ledger()
        let transport = RecordingTransport()
        let service = service(transport, wireSchema: .v3, mainThread: ledger)
        inputs.count(turns: 1_000, queued: 50)                    // before consent: never sent
        await service.setEnabled(true)
        ledger.didBecomeActive()
        inputs.at(120 * Self.second)
        ledger.didReceiveUserInput(atNanos: 120 * Self.second)
        inputs.count(turns: 40, queued: 6)
        await service.receive(HangReportFixtures.metricKitInput())

        let sent = try decoded(#require(transport.sent.first))
        #expect(sent.schema == 3)
        #expect(sent.activeSeconds == 120)
        let main = sent.intervals.filter { $0.category == HangReport.mainThreadCategory }
        #expect(main.map(\.name) == [HangReport.mainTurnInterval, HangReport.inputQueueingInterval])
        #expect(main.map(\.count) == [40, 6])

        // The same cumulative read again: no turn goes twice, and only the new active time does.
        inputs.at(150 * Self.second)
        ledger.didReceiveUserInput(atNanos: 150 * Self.second)
        await service.receive(HangReportFixtures.metricKitInput())
        let next = try decoded(#require(transport.sent.last))
        #expect(transport.sent.count == 2)
        #expect(next.activeSeconds == 30)
        #expect(!next.intervals.contains { $0.category == HangReport.mainThreadCategory })
    }

    @Test func activeTimeAloneIsSentSoTheRateHasItsDenominator() async throws {
        let inputs = Inputs()
        let ledger = inputs.ledger()
        let transport = RecordingTransport()
        let service = service(transport, wireSchema: .v3, mainThread: ledger)
        await service.setEnabled(true)
        ledger.didBecomeActive()
        inputs.at(45 * Self.second)
        ledger.didReceiveUserInput(atNanos: 45 * Self.second)
        await service.launched()
        let sent = try decoded(#require(transport.sent.first))
        #expect(sent.activeSeconds == 45)
        #expect(sent.hangs.isEmpty)
    }

    @Test func schemaTwoNeitherReadsNorSendsTheMainThreadPart() async throws {
        let inputs = Inputs()
        let ledger = inputs.ledger()
        let transport = RecordingTransport()
        let service = service(transport, mainThread: ledger)
        await service.setEnabled(true)
        ledger.didBecomeActive()
        inputs.at(45 * Self.second)
        ledger.didReceiveUserInput(atNanos: 45 * Self.second)
        inputs.count(turns: 9)
        await service.receive(HangReportFixtures.metricKitInput())
        let body = try #require(transport.sent.first)
        #expect(!String(decoding: body, as: UTF8.self).contains("active_seconds"))
        #expect(try decoded(body).intervals.allSatisfy { $0.category != HangReport.mainThreadCategory })
        #expect(ledger.take().input.activeSeconds == 45)             // nothing was committed
    }

    @Test func theMainThreadPartNotYetSentReachesTheNextLaunchsReport() async throws {
        let inputs = Inputs()
        let ledger = inputs.ledger()
        let first = service(RecordingTransport(), wireSchema: .v3, mainThread: ledger)
        await first.setEnabled(true)
        ledger.didBecomeActive()
        inputs.at(200 * Self.second)
        ledger.didReceiveUserInput(atNanos: 200 * Self.second)
        inputs.count(turns: 12)
        first.saveForNextLaunch()

        let next = Inputs()
        let transport = RecordingTransport()
        let second = service(transport, wireSchema: .v3, mainThread: next.ledger())
        await second.setEnabled(true)
        await second.launched()
        let sent = try decoded(#require(transport.sent.first))
        #expect(sent.activeSeconds == 200)
        #expect(sent.intervals.first { $0.name == HangReport.mainTurnInterval }?.count == 12)
    }
}
