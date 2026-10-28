import AppKit
@testable import CmuxNextApp
import CmuxNextSettings
@testable import CmuxNextSidebar
import Foundation
import Testing

/// With the opt-in "ask before creating" on (default off), the legacy `/api/vm` create (the default link) asks the person first for a create no person
/// started: an agent's create waits in the sidebar's
/// card and sends nothing until a click on Create; Cancel sends nothing; the person's own gesture
/// creates without asking. The legacy size is the plan's default, so the card names no size.
@MainActor @Suite(.serialized) struct CloudLegacyCreateConfirmTests {
    /// Counts the creates that went out.
    @MainActor final class Sent {
        var count = 0
        func send() -> String {
            count += 1
            return "machine"
        }
    }

    func make() -> (AppServices, NSWindow) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return (AppServices(environment: AppEnvironment.current([:])), window)
    }

    /// Starts a legacy create and returns it once its card is up.
    func create(_ services: AppServices, in window: NSWindow, sent: Sent) async throws -> (Task<String, any Error>, SidebarNoticeCard) {
        let asks = services.machineAsks
        let task = Task {
            try await CloudMachineCreateFlow.legacy(name: "builder", startedByPerson: false, askFirst: true,
                                                    confirm: { await CloudPresenter.confirmCreate($0, in: window, asks: asks) },
                                                    create: { sent.send() })
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while asks.card == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5)) // test-only: waits for the create's task, bounded
        }
        return (task, try #require(asks.card, "an agent's legacy create asked nobody"))
    }

    @Test func anAgentsLegacyCreateWaitsForCreate() async throws {
        let (services, window) = make()
        defer { window.close() }
        let sent = Sent()
        let (task, card) = try await create(services, in: window, sent: sent)
        #expect(sent.count == 0, "the legacy create went out before the person answered")
        #expect(card.title == CloudStrings.createConfirmTitle)
        #expect(card.lines == [CloudStrings.createConfirmName("builder")], "the card claims a size the legacy create does not choose")

        let yes = try #require(card.actions.first { $0.prominent })
        SidebarCardFeed.handle(.noticeAction(card: card.id, action: yes.id), services: services)
        #expect(try await task.value == "machine")
        #expect(sent.count == 1)
    }

    @Test func cancelSendsNoLegacyCreate() async throws {
        let (services, window) = make()
        defer { window.close() }
        let sent = Sent()
        let (task, card) = try await create(services, in: window, sent: sent)
        let no = try #require(card.actions.first { !$0.prominent })
        SidebarCardFeed.handle(.noticeAction(card: card.id, action: no.id), services: services)
        await #expect(throws: CloudMachineCreateFlow.Failure.declined) { try await task.value }
        #expect(sent.count == 0, "a declined legacy create went out")
    }

    @Test func thePersonsOwnLegacyCreateAsksNothing() async throws {
        let (services, _) = make()
        let sent = Sent(), asked = Sent()
        let made = try await CloudMachineCreateFlow.legacy(name: nil, startedByPerson: true,
                                                           confirm: { _ in asked.send().isEmpty },
                                                           create: { sent.send() })
        #expect(made == "machine")
        #expect(asked.count == 0 && sent.count == 1 && services.machineAsks.card == nil)
    }
}
