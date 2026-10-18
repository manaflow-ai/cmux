import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextFloating
import Foundation
import Testing

/// The Chief pet hears the notification service: what would alert on this Mac reaches its bubble,
/// a click on the bubble opens that tab, a read tab's notice leaves, and a finished turn leaves on its own.
@MainActor @Suite(.serialized) struct ChiefPetNoticeTests {

    @MainActor
    final class Harness {
        let store = DaemonStore()
        let service = NotificationCenterService()
        let clock = ManualClock()
        let defaults: UserDefaults
        let controller: ChiefPetController
        var opened: [UInt64] = []

        init() {
            _ = NSApplication.shared
            let name = "ChiefPetFeedTests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            let tabs = [1, 2].map { TabSnapshot(surface: SurfaceID(rawValue: $0), terminalResourceID: ResourceID(rawValue: "term_\($0)")) }
            store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "api-server", screens: [
                ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: tabs)]),
            ])]))
            service.clock = clock
            service.desktopPostingEnabled = false
            service.terminalNotificationsEnabled = { true }
            var opened: (ChiefPetNotice) -> Void = { _ in }
            controller = ChiefPetController(enabled: { false }, makePanel: { [defaults] in ChiefPetPanel(image: nil, defaults: defaults) },
                                            onClick: {}, onOpen: { opened($0) }, clock: clock)
            opened = { [weak self] in self?.opened.append($0.id) }
            service.chiefPet = controller.hooks
            controller.sync(true)
        }

        func deliver(_ id: UInt64, surface: UInt64, title: String, level: String = "info", alerts: Bool = true) throws {
            let wire = #"{"notification":\#(id),"title":"\#(title)","body":"","level":"\#(level)","surface":\#(surface),"source":"agent"}"#
            let notification = try JSONDecoder().decode(DaemonNotification.self, from: Data(wire.utf8))
            store.apply(.notification(notification))
            let located = try #require(service.locate(surface: SurfaceID(rawValue: surface), in: store))
            var decision = NotificationPolicy.Decision()
            decision.alerts = alerts
            service.deliver(notification, source: .agent, located: located, decision: decision, program: nil)
        }

        func read(surface: UInt64) throws {
            service.acknowledge(try #require(service.locate(surface: SurfaceID(rawValue: surface), in: store)).tab)
        }

        var titles: [String] { controller.feed.notices.map(\.title) }

    }

    @Test func alertsReachTheBubbleAndAReadTabLeavesIt() throws {
        let harness = Harness()
        defer { harness.controller.sync(false) }
        try harness.deliver(5, surface: 1, title: "Claude needs approval", level: "warning")
        try harness.deliver(6, surface: 2, title: "Codex finished")
        #expect(harness.titles == ["Codex finished", "Claude needs approval"])
        #expect(harness.controller.bubble?.isVisible == true)
        #expect(harness.controller.panel?.pet.badge == 1)
        harness.controller.bubble?.onClick?()
        #expect(harness.opened == [6], "a bubble click opens the front notice's tab")
        try harness.read(surface: 1)
        #expect(harness.titles == ["Codex finished"])
        #expect(harness.controller.panel?.pet.badge == 0)
    }

    @Test func whatWouldNotAlertStaysOffThePet() throws {
        let harness = Harness()
        defer { harness.controller.sync(false) }
        // A muted workspace, quiet hours, or `notifications.desktop` = never.
        try harness.deliver(5, surface: 1, title: "Claude finished", alerts: false)
        #expect(harness.titles.isEmpty)
        #expect(harness.controller.bubble?.isVisible != true)
    }

    @Test func finishedNoticeLeavesOnItsOwn() async throws {
        let harness = Harness()
        defer { harness.controller.sync(false) }
        try harness.deliver(5, surface: 1, title: "Claude finished")
        try await harness.clock.waitForSleeper()
        harness.clock.advance(by: .seconds(ChiefPetController.doneSeconds + 1))
        for _ in 0..<1000 where !harness.titles.isEmpty { await Task.yield() }
        #expect(harness.titles.isEmpty)
        #expect(harness.controller.bubble?.isVisible == false)
    }
}
