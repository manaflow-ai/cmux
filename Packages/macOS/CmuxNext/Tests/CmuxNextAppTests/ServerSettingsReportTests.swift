import Foundation
import Testing
@testable import CmuxNextUpdater

/// Settings > Server (plans/cmux-next/server-updates-DESIGN.md, section 10): the server's status,
/// version line, "Restart Recommended" row, local socket and tailnet address, from the same
/// handshakes the restart toast reads. Nothing restarts from reading the report.
@MainActor
@Suite(.serialized)
struct ServerSettingsReportTests {
    private static let catalog = ServerFeatureCatalog(entries: [
        .init(capability: "tab-groups-v1", title: "Tab groups"),
        .init(capability: "workspace-checklist-v1", title: "Workspace checklists"),
    ])
    private static let app: Set<String> = ["rows-v1", "tab-groups-v1", "workspace-checklist-v1"]

    private static func old() -> ServerHandshake {
        ServerHandshake(kind: .cmuxTUI, host: .local, build: "old1234", protocolVersion: 12,
                        capabilities: ["rows-v1"], version: "0.66.0")
    }

    private static func current() -> ServerHandshake {
        ServerHandshake(kind: .cmuxTUI, host: .local, build: "new5678", protocolVersion: 12,
                        capabilities: app, version: "0.67.0")
    }

    private static func coordinator(defaults: UserDefaults? = nil) -> ServerUpdateCoordinator {
        let name = "ServerSettingsReportTests.\(UUID().uuidString)"
        let suite = defaults ?? UserDefaults(suiteName: name)!
        return ServerUpdateCoordinator(policy: ServerSkewPolicy(catalog: catalog), restarter: NeverRestarter(),
                                       snoozes: ServerUpdateSnoozeStore(defaults: suite))
    }

    @Test func aRunningCurrentServerShowsStatusVersionAndNoRestartRow() throws {
        let center = Self.coordinator()
        center.report(Self.current(), appCapabilities: Self.app, bundledBuild: "new5678")
        let report = center.settingsReport(socketPath: "/tmp/cmux.sock", tailnetAddress: "100.64.0.7")
        let row = try #require(report.rows.first)
        #expect(report.rows.count == 1)
        #expect(row.isRunning)
        #expect(row.versionLine.contains("0.67.0"))
        #expect(row.versionLine.contains("new5678"))
        #expect(row.versionLine.contains("12"), "the protocol version is in the line")
        #expect(row.restart == nil)
        #expect(row.socketPath == "/tmp/cmux.sock")
        #expect(row.tailnetAddress == "100.64.0.7")
    }

    @Test func anOlderServerShowsRestartRecommendedWithTheFeaturesItGains() throws {
        let center = Self.coordinator()
        center.report(Self.old(), appCapabilities: Self.app, bundledBuild: "new5678")
        let row = try #require(center.settingsReport(socketPath: nil, tailnetAddress: nil).rows.first)
        let restart = try #require(row.restart)
        #expect(restart.help.contains("Tab groups"))
        #expect(restart.buttonTitle.contains("cmux-tui"))
        #expect(restart.kind == .cmuxTUI)
        #expect(row.socketPath == nil)
        #expect(row.tailnetAddress == nil)
    }

    /// The close button snoozes the toast for a day; the Settings row stays, since the person
    /// went looking for it.
    @Test func aSnoozedToastDoesNotHideTheRestartRow() throws {
        let center = Self.coordinator()
        center.report(Self.old(), appCapabilities: Self.app, bundledBuild: "new5678")
        center.snooze(try #require(center.notices.first))
        #expect(center.notices.isEmpty)
        let row = try #require(center.settingsReport(socketPath: nil, tailnetAddress: nil).rows.first)
        #expect(row.restart != nil)
    }

    @Test func readingTheReportNeverRestarts() async {
        let restarter = NeverRestarter()
        let center = ServerUpdateCoordinator(
            policy: ServerSkewPolicy(catalog: Self.catalog), restarter: restarter,
            snoozes: ServerUpdateSnoozeStore(defaults: UserDefaults(suiteName: "ServerSettingsReportTests.\(UUID().uuidString)")!))
        center.report(Self.old(), appCapabilities: Self.app, bundledBuild: "new5678")
        _ = center.settingsReport(socketPath: nil, tailnetAddress: nil)
        #expect(restarter.calls == 0)
    }

    @Test func noServerHeardFromYetIsAnEmptyReport() {
        #expect(Self.coordinator().settingsReport(socketPath: nil, tailnetAddress: nil).rows.isEmpty)
    }
}

@MainActor
private final class NeverRestarter: ServerRestarting {
    private(set) var calls = 0
    func restart(_ kind: ServerKind, host: ServerHost) async throws -> ServerHandshake {
        calls += 1
        throw CancellationError()
    }
}

/// `cmux host status --json` lists the addresses other devices dial; Settings shows the first.
@Suite struct ServerTailnetAddressTests {
    @Test func theFirstListedAddressIsShown() {
        let json = #"{"enabled":true,"serving":true,"addresses":["100.64.0.7:7777","[fd7a::7]:7777"]}"#
        #expect(ServerTailnetAddress(hostStatus: Data(json.utf8))?.value == "100.64.0.7:7777")
    }

    @Test func noAddressMeansNoRow() {
        #expect(ServerTailnetAddress(hostStatus: Data(#"{"addresses":[]}"#.utf8)) == nil)
        #expect(ServerTailnetAddress(hostStatus: Data(#"{"enabled":false}"#.utf8)) == nil)
        #expect(ServerTailnetAddress(hostStatus: Data("not json".utf8)) == nil)
    }
}
