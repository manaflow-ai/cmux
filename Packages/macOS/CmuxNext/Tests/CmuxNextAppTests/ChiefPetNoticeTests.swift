import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextFloating
import CmuxNextSettings
import Foundation
import Testing
import CmuxNextWakeupsTestSupport

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
        /// Whether cmux is the active app, as the pet reads it; `activate` changes it.
        var active = true
        /// Where the test posts the app's activation changes.
        let center = NotificationCenter()

        init() {
            _ = NSApplication.shared
            let name = "ChiefPetFeedTests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            let tabs = [1, 2].map { TabSnapshot(surface: SurfaceID(rawValue: $0), terminalResourceID: ResourceID(rawValue: "term_\($0)"), title: "New chat") }
            store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "api-server", screens: [
                ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: tabs)]),
            ])]))
            service.clock = clock
            service.desktopPostingEnabled = false
            service.terminalNotificationsEnabled = { true }
            var opened: (ChiefPetReplyTarget) -> Void = { _ in }
            var isActive: @MainActor () -> Bool = { true }
            controller = ChiefPetController(makePanel: { [defaults] in ChiefPetPanel(defaults: defaults) },
                                            actions: ChiefPetActions(open: { opened($0) }, send: { _, _ in false }), clock: clock,
                                            appIsActive: { isActive() }, notifications: center)
            opened = { [weak self] target in
                if case .notice(let notice) = target { self?.opened.append(notice.id) }
            }
            isActive = { [weak self] in self?.active ?? true }
            service.chiefPet = controller
            controller.sync(true)
        }

        func deliver(_ id: UInt64, surface: UInt64, title: String, body: String = "", level: String = "info", alerts: Bool = true,
                     source: String = "agent", reply: Bool = false) throws {
            let wire = #"{"notification":\#(id),"title":"\#(title)","body":"\#(body)","level":"\#(level)","surface":\#(surface),"source":"\#(source)","reply":\#(reply)}"#
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

        /// cmux becomes (or stops being) the active app, as AppKit reports it.
        func activate(_ active: Bool) {
            self.active = active
            center.post(name: active ? NSApplication.didBecomeActiveNotification : NSApplication.didResignActiveNotification, object: nil)
        }

        /// Moves the clock past `seconds` once a timer sleeps on it, and lets what fired run.
        func advance(_ seconds: Double) async throws {
            try await clock.waitForSleeper()
            clock.advance(by: .seconds(seconds))
            for _ in 0..<200 { await Task.yield() }
        }

    }

    @Test func alertsReachTheBubbleAndAReadTabLeavesIt() throws {
        let harness = Harness()
        defer { harness.controller.sync(false) }
        try harness.deliver(5, surface: 1, title: "Claude needs approval", level: "warning")
        try harness.deliver(6, surface: 2, title: "Codex finished")
        #expect(harness.titles == ["Codex finished", "Claude needs approval"])
        #expect(harness.controller.bubble?.isVisible == true)
        #expect(harness.controller.panel?.pet.badge == 1)
        harness.controller.bubble?.onOpen?(0)
        #expect(harness.opened == [6], "a click on the front capsule opens its tab")
        #expect(harness.controller.feed.notices.allSatisfy { $0.reply == .type }, "terminal notices take a typed reply")
        try harness.read(surface: 1)
        #expect(harness.titles == ["Codex finished"])
        #expect(harness.controller.panel?.pet.badge == 0)
    }

    @Test func noticeReadsAsTheBanner() throws {
        let harness = Harness()
        defer { harness.controller.sync(false) }
        try harness.deliver(5, surface: 1, title: "Claude needs approval", level: "warning")
        let notice = try #require(harness.controller.feed.front)
        #expect(notice.title == "Claude needs approval")
        #expect(notice.detail == "api-server", "no text, no subtitle: the workspace")
        #expect(notice.kind == .needsYou)
        #expect(notice.reply == .type, "a terminal takes a typed reply")
        #expect(notice.surface == 1)
    }

    /// A notice whose poster gave no title says which chat and what happened, never a bare tab
    /// name over a bare step (Leo 2026-10-20: "New chat" / "Ran command" said neither).
    @Test func untitledNoticeSaysWhichChatAndWhatHappened() throws {
        let harness = Harness()
        defer { harness.controller.sync(false) }
        try harness.deliver(5, surface: 1, title: "", body: "Ran command")
        let finished = try #require(harness.controller.feed.front)
        #expect(finished.title == ChiefPetNotice.title("New chat", kind: .done), "\"New chat finished\" in English")
        #expect(finished.detail == "api-server · Ran command", "the workspace, then its line")
        try harness.deliver(6, surface: 2, title: "", body: "Allow rm -rf build?", level: "warning")
        #expect(harness.controller.feed.front?.title == ChiefPetNotice.title("New chat", kind: .needsYou))
        try harness.deliver(7, surface: 1, title: "", level: "error")
        #expect(harness.controller.feed.front?.title == ChiefPetNotice.title("New chat", kind: .failed))
        #expect(harness.controller.feed.front?.detail == "api-server")
        // A titleless line that is not an agent's (an OSC 9 from a shell) did not "finish" anything.
        try harness.deliver(8, surface: 2, title: "", body: "build done", source: "terminal")
        #expect(harness.controller.feed.front?.title == "New chat")
        #expect(harness.controller.feed.front?.detail == "api-server · build done")
    }

    /// Only an agent's notice, or one whose poster asked for a reply (`notify --reply`), takes typed
    /// text (like a `--reply` banner): an OSC 9/777 line from a remote shell or a log must not open a box that
    /// types into whatever runs there.
    @Test func onlyAgentsAndAskedForRepliesTakeTypedText() throws {
        let harness = Harness()
        defer { harness.controller.sync(false) }
        try harness.deliver(5, surface: 1, title: "printed by tail -f", source: "terminal")
        #expect(harness.controller.feed.front?.reply == .openTab)
        try harness.deliver(6, surface: 2, title: "asked for a reply", source: "cli", reply: true)
        #expect(harness.controller.feed.front?.reply == .type)
        try harness.deliver(7, surface: 1, title: "Claude needs approval", level: "warning")
        #expect(harness.controller.feed.front?.reply == .type)
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
        // Its card's timer sleeps on the clock too; the leave timer may have gone to sleep after the
        // advance (its deadline counts from then), so the clock moves on until it fires.
        for _ in 0..<1000 where !harness.titles.isEmpty {
            await Task.yield()
            harness.clock.advance(by: .milliseconds(100))
        }
        #expect(harness.titles.isEmpty)
        #expect(harness.controller.bubble?.isVisible == false)
    }

    /// The card is a toast (Leo 2026-10-20: it sat over Chrome for minutes): it folds away after
    /// `toastSeconds`, while a notice that waits stays on the badge and the chevron unfolds it again.
    @Test func cardFoldsAwayOnItsOwnAndTheBadgeStays() async throws {
        let harness = Harness()
        defer { harness.controller.sync(false) }
        try harness.deliver(5, surface: 1, title: "Claude needs approval", level: "warning")
        #expect(harness.controller.bubble?.isVisible == true)
        try await harness.advance(ChiefPetController.toastSeconds + 1)
        #expect(harness.controller.bubble?.isVisible == false, "the card folds away")
        #expect(harness.titles == ["Claude needs approval"], "the notice still waits")
        #expect(harness.controller.panel?.pet.badge == 1)
        harness.controller.panel?.onExpand?()
        #expect(harness.controller.bubble?.isVisible == true, "the chevron unfolds what waits")
    }

    /// An agent posting the same notice again (its next tool call) does not keep the card up.
    @Test func theSameNoticePostedAgainDoesNotKeepTheCardUp() async throws {
        let harness = Harness()
        defer { harness.controller.sync(false) }
        try harness.deliver(5, surface: 1, title: "Claude needs approval", level: "warning")
        try await harness.advance(ChiefPetController.toastSeconds / 2)
        try harness.deliver(6, surface: 1, title: "Claude needs approval", level: "warning")
        #expect(harness.controller.bubble?.isVisible == true)
        harness.clock.advance(by: .seconds(ChiefPetController.toastSeconds / 2 + 1))
        for _ in 0..<1000 where harness.controller.bubble?.isVisible == true { await Task.yield() }
        #expect(harness.controller.bubble?.isVisible == false)
    }

    /// The card shows over cmux only, never over another app's window (Leo 2026-10-20: it floated
    /// over Chrome and Edge); there the pet's badge counts what waits. The chevron still unfolds it.
    @Test func cardShowsOverCmuxOnly() throws {
        let harness = Harness()
        defer { harness.controller.sync(false) }
        harness.active = false
        try harness.deliver(5, surface: 1, title: "Claude needs approval", level: "warning")
        #expect(harness.controller.bubble?.isVisible != true, "another app is in front: no card")
        #expect(harness.controller.panel?.pet.badge == 1)
        harness.activate(true)
        #expect(harness.controller.bubble?.isVisible == true, "back in cmux within its time: the card shows")
        harness.activate(false)
        #expect(harness.controller.bubble?.isVisible == false, "switching away takes it down at once")
        harness.controller.panel?.onExpand?()
        #expect(harness.controller.bubble?.isVisible == true, "the chevron is asked for: it shows anywhere")
    }
}
