import CmuxConnectivityTelemetry
@testable import CmuxMobileLive
import CmuxMobileTransport
import Foundation
import Testing

/// The phone's link reports its dials, failures and phases to connectivity telemetry, verbose
/// for the cmux team and text-free for everyone else.
@MainActor
@Suite struct LinkConnectivityTelemetryTests {
    private func failingDial(audience: ConnectivityAudience) async -> [ConnectivityRecord] {
        let telemetry = ConnectivityTelemetry()
        telemetry.setAudience(audience)
        let journal = ConnectivityJournal(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("link-cct-\(UUID().uuidString)", isDirectory: true))
        telemetry.setJournal(journal)
        let controller = LinkController(transport: .webRTC, dialer: MockDialer(fail: true), telemetry: telemetry,
                                        accessToken: { _ in "t" })
        controller.endpoint = { LinkEndpoint(baseURL: URL(string: "https://api.example")!, teamID: "team-1", deviceID: "d", macDeviceID: $0) }
        controller.send(.target(LinkMachine.Target(macID: "mac-42", name: "Mac", isOnline: true)))
        for _ in 0..<200 { if case .waiting = controller.phase { break }; await Task.yield() }
        await telemetry.flush()
        return journal.records()
    }

    @Test func teamSeesTheFailedDialInFull() async throws {
        let records = await failingDial(audience: .team)
        let start = try #require(records.first { $0.name == "dial_start" })
        #expect(start.fields["mac_id"] == .text("mac-42"))
        #expect(start.detail == "https://api.example")
        let failed = try #require(records.first { $0.name == "dial_failed" })
        #expect(failed.outcome == .failure)
        #expect(failed.fields["error_code"] == .code("timeout"))
        #expect(failed.detail?.contains("timeout") == true)
        let waiting = try #require(records.last { $0.name == "phase" && $0.fields["phase"] == .code("waiting") })
        #expect(waiting.fields["reason"] == .text("the Mac didn't answer in time"))
    }

    @Test func everyoneSeesTheFailureWithoutIdentifiers() async throws {
        let records = await failingDial(audience: .everyone)
        let failed = try #require(records.first { $0.name == "dial_failed" })
        #expect(failed.fields["error_code"] == .code("timeout"))
        #expect(failed.detail == nil)
        let waiting = try #require(records.last { $0.name == "phase" && $0.fields["phase"] == .code("waiting") })
        #expect(waiting.fields["reason"] == nil)
        for record in records {
            #expect(!record.jsonLine().contains("mac-42"))
            #expect(!record.jsonLine().contains("team-1"))
            #expect(!record.jsonLine().contains("api.example"))
        }
    }
}
