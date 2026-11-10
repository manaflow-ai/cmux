import CmuxConnectivityTelemetry
@testable import CmuxNextMobile
import Foundation
import Testing

/// The Mac's phone host reports each phase to connectivity telemetry: a waiting host's reason
/// and the Mac's ids reach the cmux team's journal, and never everyone's.
struct MobileHostConnectivityTelemetryTests {
    private func waitingHost() -> MobileHostState {
        var state = MobileHostState(phase: .waiting("cmux-mobile-host exited with status 1: relay wss://relay.example refused"))
        state.teamID = "team-7"
        state.deviceID = "mac-device-9"
        return state
    }

    private func journal(for audience: ConnectivityAudience, states: [MobileHostState]) async -> [ConnectivityRecord] {
        let telemetry = ConnectivityTelemetry()
        telemetry.setAudience(audience)
        let journal = ConnectivityJournal(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-cct-\(UUID().uuidString)", isDirectory: true))
        telemetry.setJournal(journal)
        for state in states { telemetry.record(MobileHostConnectivityEvent(state).event) }
        await telemetry.flush()
        return journal.records()
    }

    @Test func teamJournalHasTheReasonAndIDs() async throws {
        let record = try #require(await journal(for: .team, states: [waitingHost()]).first)
        #expect(record.area == .phoneHost)
        #expect(record.outcome == .failure)
        #expect(record.fields["phase"] == .code("waiting"))
        #expect(record.fields["reason"] == .text("cmux-mobile-host exited with status 1: relay wss://relay.example refused"))
        #expect(record.fields["device_id"] == .text("mac-device-9"))
    }

    @Test func everyoneJournalHasThePhaseOnly() async throws {
        let records = await journal(for: .everyone, states: [MobileHostState(phase: .connecting), waitingHost(), MobileHostState(phase: .online)])
        #expect(records.map { $0.fields["phase"] } == [.code("connecting"), .code("waiting"), .code("online")])
        let waiting = try #require(records.first { $0.outcome == .failure })
        #expect(waiting.fields["reason"] == nil)
        #expect(waiting.fields["phones"] == .number(0))
        for record in records {
            let line = record.jsonLine()
            #expect(!line.contains("relay.example"))
            #expect(!line.contains("team-7"))
            #expect(!line.contains("mac-device-9"))
        }
    }
}
