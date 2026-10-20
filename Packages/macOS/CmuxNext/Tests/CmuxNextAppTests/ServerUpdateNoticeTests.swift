import Foundation
import Testing
@testable import CmuxNextUpdater

/// Server updates (plans/cmux-next/server-updates-DESIGN.md): an app newer than its cmux-tui or
/// acpmux keeps working on the older protocol, names the features a restart turns on, and restarts
/// only after the person confirms.
@MainActor
@Suite(.serialized)
struct ServerUpdateNoticeTests {
    private static let catalog = ServerFeatureCatalog(entries: [
        .init(capability: "tab-groups-v1", title: "Tab groups"),
        .init(capability: "workspace-checklist-v1", title: "Workspace checklists"),
        .init(capability: "browser-profiles-v1", title: "Browser profiles"),
        .init(capability: "workspace-pin-v1", title: "Pinned workspaces"),
    ])
    private static let app: Set<String> = [
        "workspace-registry-v1", "tab-groups-v1", "workspace-checklist-v1", "browser-profiles-v1",
        "workspace-pin-v1", "shared-sizing-v1", "rows-v1",
    ]

    private static func oldDaemon(_ host: ServerHost = .local) -> ServerHandshake {
        ServerHandshake(kind: .cmuxTUI, host: host, build: "old1234", protocolVersion: 12,
                        capabilities: ["workspace-registry-v1", "rows-v1"])
    }

    private static func newDaemon(_ host: ServerHost = .local) -> ServerHandshake {
        ServerHandshake(kind: .cmuxTUI, host: host, build: "new5678", protocolVersion: 12, capabilities: app)
    }

    private static func defaults() -> UserDefaults {
        let name = "ServerUpdateNoticeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static func coordinator(_ restarter: FakeRestarter, now: Date = Date(timeIntervalSince1970: 1_000_000),
                                    defaults: UserDefaults = defaults()) -> ServerUpdateCoordinator {
        ServerUpdateCoordinator(policy: ServerSkewPolicy(catalog: catalog), restarter: restarter,
                                snoozes: ServerUpdateSnoozeStore(defaults: defaults), now: { now })
    }

    /// Version skew: the features the old daemon lacks are off, and the notice names them.
    @Test func anOlderDaemonTurnsItsMissingCapabilitiesOffAndNamesThem() throws {
        let center = Self.coordinator(FakeRestarter(next: Self.newDaemon()))
        center.report(Self.oldDaemon(), appCapabilities: Self.app, bundledBuild: "new5678")

        #expect(!center.supports("tab-groups-v1", kind: .cmuxTUI, host: .local))
        #expect(center.supports("rows-v1", kind: .cmuxTUI, host: .local))
        let notice = try #require(center.notices.first)
        #expect(center.notices.count == 1)
        #expect(notice.kind == .cmuxTUI)
        #expect(notice.gainedFeatures.map(\.title).prefix(3) == ["Tab groups", "Workspace checklists", "Browser profiles"])
        #expect(notice.missingCapabilities.contains("shared-sizing-v1"))
        #expect(notice.toastMessage.contains("cmux-tui"))
        #expect(notice.toastMessage.contains("Tab groups"))
        #expect(notice.toastMessage.contains("2"), "four named features show three and \"2 more\" (pinned + shared sizing)")
        #expect(notice.restartButtonTitle.contains("cmux-tui"))
    }

    /// A daemon that already serves everything the app uses shows nothing.
    @Test func aCurrentDaemonShowsNoNotice() {
        let center = Self.coordinator(FakeRestarter(next: Self.newDaemon()))
        center.report(Self.newDaemon(), appCapabilities: Self.app, bundledBuild: "new5678")
        #expect(center.notices.isEmpty)
        #expect(center.supports("tab-groups-v1", kind: .cmuxTUI, host: .local))
    }

    /// Reporting skew never restarts anything: only a confirmed restart does.
    @Test func skewAloneNeverRestarts() {
        let restarter = FakeRestarter(next: Self.newDaemon())
        let center = Self.coordinator(restarter)
        center.report(Self.oldDaemon(), appCapabilities: Self.app, bundledBuild: "new5678")
        center.report(Self.oldDaemon(), appCapabilities: Self.app, bundledBuild: "new5678")
        #expect(restarter.calls.isEmpty)
        #expect(center.notices.count == 1, "the same skew again is one notice, not two")
    }

    /// Restart: the new daemon's capabilities turn on and the notice ends.
    @Test func aRestartTurnsTheNewCapabilitiesOnAndEndsTheNotice() async throws {
        let restarter = FakeRestarter(next: Self.newDaemon())
        let center = Self.coordinator(restarter)
        center.report(Self.oldDaemon(), appCapabilities: Self.app, bundledBuild: "new5678")
        let notice = try #require(center.notices.first)

        let outcome = await center.restart(notice)

        #expect(restarter.calls == [.init(kind: .cmuxTUI, host: .local)])
        #expect(outcome == .restarted(gained: notice.gainedFeatures))
        #expect(center.supports("tab-groups-v1", kind: .cmuxTUI, host: .local))
        #expect(center.notices.isEmpty)
    }

    /// A restart whose successor still lacks the features (an external binary) says so and does
    /// not offer the same restart again in a loop.
    @Test func aRestartThatGainsNothingReportsItOnce() async throws {
        let center = Self.coordinator(FakeRestarter(next: Self.oldDaemon()))
        center.report(Self.oldDaemon(), appCapabilities: Self.app, bundledBuild: "new5678")
        let notice = try #require(center.notices.first)
        let outcome = await center.restart(notice)
        #expect(outcome == .stillMissing(notice.missingCapabilities))
        #expect(center.notices.isEmpty)
    }

    /// The close button snoozes that server build for a day; a newer server build is a new notice.
    @Test func closingSnoozesThatBuildForADay() throws {
        let defaults = Self.defaults()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let center = Self.coordinator(FakeRestarter(next: Self.newDaemon()), now: start, defaults: defaults)
        center.report(Self.oldDaemon(), appCapabilities: Self.app, bundledBuild: "new5678")
        center.snooze(try #require(center.notices.first))
        #expect(center.notices.isEmpty)

        // The next launch, an hour later: still snoozed (persisted).
        let later = Self.coordinator(FakeRestarter(next: Self.newDaemon()), now: start.addingTimeInterval(3600), defaults: defaults)
        later.report(Self.oldDaemon(), appCapabilities: Self.app, bundledBuild: "new5678")
        #expect(later.notices.isEmpty)

        // A day later it shows again.
        let tomorrow = Self.coordinator(FakeRestarter(next: Self.newDaemon()), now: start.addingTimeInterval(25 * 3600), defaults: defaults)
        tomorrow.report(Self.oldDaemon(), appCapabilities: Self.app, bundledBuild: "new5678")
        #expect(tomorrow.notices.count == 1)
    }

    /// Each host gets its own notice: a Mac mini's old daemon does not hide the local one's.
    @Test func eachHostHasItsOwnNotice() {
        let center = Self.coordinator(FakeRestarter(next: Self.newDaemon()))
        center.report(Self.oldDaemon(), appCapabilities: Self.app, bundledBuild: "new5678")
        center.report(Self.oldDaemon(.remote("cmux-mini")), appCapabilities: Self.app, bundledBuild: "new5678")
        #expect(Set(center.notices.map(\.host)) == [.local, .remote("cmux-mini")])
        #expect(center.notices.first { $0.host == .remote("cmux-mini") }?.toastMessage.contains("cmux-mini") == true)
    }

    /// acpmux advertises no capabilities yet: another build is a notice with no feature list, and
    /// an acpmux without agent hosts warns that running agents end.
    @Test func anOlderAcpmuxWithoutAgentHostsWarnsThatAgentsEnd() throws {
        let center = Self.coordinator(FakeRestarter(next: Self.newDaemon()))
        center.report(ServerHandshake(kind: .acpmux, host: .local, build: "acp-old", protocolVersion: nil,
                                      capabilities: nil, keepsWorkAcrossRestart: false),
                      appCapabilities: [], bundledBuild: "acp-new")
        let notice = try #require(center.notices.first)
        #expect(notice.kind == .acpmux)
        #expect(notice.gainedFeatures.isEmpty)
        #expect(notice.toastMessage.contains("acpmux"))
        #expect(notice.impact.isDestructive)
        #expect(!notice.impact.lost.isEmpty)
        #expect(notice.confirmSpec.buttons.contains { $0.role == .destructive })
    }

    /// The cmux-tui confirm says terminals survive and only a short reconnect is lost.
    @Test func theCmuxTUIConfirmSaysTerminalsSurvive() throws {
        let center = Self.coordinator(FakeRestarter(next: Self.newDaemon()))
        center.report(Self.oldDaemon(), appCapabilities: Self.app, bundledBuild: "new5678")
        let notice = try #require(center.notices.first)
        #expect(!notice.impact.isDestructive)
        #expect(!notice.impact.kept.isEmpty)
        #expect(notice.confirmSpec.title.contains("cmux-tui"))
        #expect(notice.confirmSpec.defaultButton != nil)
        #expect(notice.confirmSpec.cancelButton != nil)
    }

    /// Every capability the shipped catalog names is one the app actually gates on.
    @Test func theShippedCatalogNamesOnlyKnownCapabilities() {
        let shipped = ServerFeatureCatalog.shipped
        #expect(!shipped.entries.isEmpty)
        #expect(Set(shipped.entries.map(\.capability)).count == shipped.entries.count)
        for entry in shipped.entries {
            #expect(entry.capability.hasSuffix("-v1") || entry.capability.hasSuffix("-v2"), "\(entry.capability)")
            #expect(!entry.title.isEmpty)
        }
    }
}

/// A restarter that records each call and answers with a fixed successor handshake.
@MainActor
private final class FakeRestarter: ServerRestarting {
    struct Call: Equatable {
        let kind: ServerKind
        let host: ServerHost
    }

    private(set) var calls: [Call] = []
    let next: ServerHandshake

    init(next: ServerHandshake) { self.next = next }

    func restart(_ kind: ServerKind, host: ServerHost) async throws -> ServerHandshake {
        calls.append(Call(kind: kind, host: host))
        return next
    }
}
