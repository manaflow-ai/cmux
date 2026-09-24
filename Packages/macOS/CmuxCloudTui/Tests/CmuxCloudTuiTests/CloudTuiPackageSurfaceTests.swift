import Foundation
import Testing
import CmuxCloudTui

/// Exercises the transport through its public surface only, the way the app
/// target consumes it after the move.
@Suite struct CloudTuiPackageSurfaceTests {
    @Test func shellQuoteLeavesSafeWordsAndQuotesTheRest() {
        #expect(CloudTuiCommandLine.shellQuote("") == "''")
        #expect(CloudTuiCommandLine.shellQuote("/tmp/cmux.sock") == "/tmp/cmux.sock")
        #expect(CloudTuiCommandLine.shellQuote("it's") == "'it'\\''s'")
    }

    @Test func gridRejectsDimensionsOutsideTheSupportedRange() {
        #expect(CloudTuiManualIOGrid(columns: 1, rows: 24) == nil)
        #expect(CloudTuiManualIOGrid(columns: 80, rows: 10_001) == nil)
        #expect(CloudTuiManualIOGrid(columns: 80, rows: 24)?.columns == 80)
    }

    @Test func resizeSchedulerKeepsOneRequestInFlightAndSendsTheNewestNext() throws {
        let small = try #require(CloudTuiManualIOGrid(columns: 80, rows: 24))
        let medium = try #require(CloudTuiManualIOGrid(columns: 100, rows: 30))
        let large = try #require(CloudTuiManualIOGrid(columns: 120, rows: 40))
        var scheduler = CloudTuiManualIOResizeScheduler()
        #expect(scheduler.sample(small, canSend: true) == small)
        #expect(scheduler.sample(medium, canSend: true) == nil)
        #expect(scheduler.sample(large, canSend: true) == nil)
        #expect(scheduler.acknowledge(canSend: true) == large)
        #expect(scheduler.lastAcknowledged == small)
    }

    @Test func legacyParserReadsNothingFromMalformedData() {
        #expect(CloudTuiLegacySnapshotParser().protocolVersion(from: Data("not json".utf8)) == nil)
    }
}
