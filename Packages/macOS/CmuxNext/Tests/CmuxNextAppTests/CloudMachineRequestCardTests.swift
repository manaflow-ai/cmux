import AppKit
@testable import CmuxNextApp
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// An agent's or a script's request for a Cloud machine waits in the sidebar's card, not in a
/// sheet over the person's work: the card names the machine and that it counts against the
/// Cloud plan, Create is the one yes, Cancel and the x say no, and the card shows over every
/// other bottom-left card (a staged update too) so the agent never waits on a hidden question.
@MainActor @Suite(.serialized, .closesItsWindows) struct CloudMachineRequestCardTests {
    static let machine = CloudMachineCreateFlow.Machine(name: "builder", cpu: 2, memoryMB: 4096, diskMB: 16384)

    func make() -> (AppServices, NSWindow) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return (AppServices(environment: AppEnvironment.current([:])), window)
    }

    /// Starts the agent's request and returns it once its card is up.
    func ask(_ services: AppServices, in window: NSWindow?) async throws -> (Task<Bool, Never>, SidebarNoticeCard) {
        let asks = services.machineAsks
        let answer = Task { await CloudPresenter.confirmCreate(.agentRequest(Self.machine), in: window, asks: asks) }
        let deadline = ContinuousClock.now + .seconds(5)
        while asks.card == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5)) // test-only: waits for the request's task, bounded
        }
        return (answer, try #require(asks.card, "the agent's request shows no sidebar card"))
    }

    @Test func anAgentsRequestWaitsInTheSidebarCardAndCreatesOnlyOnCreate() async throws {
        let (services, window) = make()
        defer { window.close() }
        let (answer, card) = try await ask(services, in: window)
        #expect(card.title == CloudStrings.createConfirmTitle)
        #expect(card.detail == CloudStrings.createRequestDetail, "the card does not say who asked or that it counts against the plan")
        #expect(card.lines == [CloudStrings.createConfirmName("builder"), CloudStrings.createConfirmSize(cpu: 2, memoryGB: 4, diskGB: 16)])
        #expect(card.actions.map(\.title) == [CloudStrings.createConfirmButton, CloudStrings.cancel])
        #expect(card.actions.filter(\.prominent).map(\.title) == [CloudStrings.createConfirmButton])
        #expect(card.awaitsAnswer)
        #expect(SidebarCardFeed.noticeCard(services.updater, registry: nil) != card, "the update feed owns the request card")

        // Another card's button, even one with the same action id, does not answer it.
        SidebarCardFeed.handle(.noticeAction(card: "another-card", action: "yes"), services: services)
        #expect(services.machineAsks.card == card)

        let create = try #require(card.actions.first { $0.prominent })
        SidebarCardFeed.handle(.noticeAction(card: card.id, action: create.id), services: services)
        #expect(await answer.value, "Create on the card did not approve the request")
        #expect(services.machineAsks.card == nil, "the answered card stays")
    }

    @Test func cancelOrTheXDeclinesTheRequest() async throws {
        let (services, window) = make()
        defer { window.close() }
        let (cancelled, card) = try await ask(services, in: window)
        let cancel = try #require(card.actions.first { !$0.prominent })
        SidebarCardFeed.handle(.noticeAction(card: card.id, action: cancel.id), services: services)
        #expect(await cancelled.value == false, "Cancel approved the request")

        let (dismissed, second) = try await ask(services, in: window)
        SidebarCardFeed.handle(.dismissNotice(second.id), services: services)
        #expect(await dismissed.value == false, "the x approved the request")
        #expect(services.machineAsks.card == nil)
    }

    @Test func noWindowOrACancelledCallerAnswersNo() async throws {
        let (services, window) = make()
        defer { window.close() }
        #expect(await CloudPresenter.confirmCreate(.agentRequest(Self.machine), in: nil, asks: services.machineAsks) == false)
        #expect(services.machineAsks.card == nil, "a request with no window left a card")

        let (answer, _) = try await ask(services, in: window)
        answer.cancel()
        #expect(await answer.value == false, "a cancelled request was approved")
        let deadline = ContinuousClock.now + .seconds(5)
        while services.machineAsks.card != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5)) // test-only: the cancel hops to the main actor, bounded
        }
        #expect(services.machineAsks.card == nil, "a cancelled request's card stays")
    }

    @Test func theRequestCardShowsOverAStagedUpdate() async throws {
        let (services, window) = make()
        defer { window.close() }
        _ = try DebugUpdater.run(["action": .string("stage"), "version": .string("1.0.0-nightly.3845050428001"), "changes": JSONValue(3)], services, terminate: {})
        let model = SidebarModel()
        model.updateCard = SidebarCardFeed.updateCard(services.updater)
        #expect(model.updateCard != nil, "no staged update card")
        let sidebar = SidebarView(model: model, design: DesignSettings())
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: Metrics.sidebarWidth, height: 640)
        sidebar.layoutSubtreeIfNeeded()
        #expect(!sidebar.cardSlot.showsNotice)

        let (answer, card) = try await ask(services, in: window)
        defer { answer.cancel() }
        model.noticeCard = card
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            sidebar.needsLayout = true
            sidebar.layoutSubtreeIfNeeded()
            if sidebar.cardSlot.showsNotice { break }
            try await Task.sleep(for: .milliseconds(5)) // test-only: waits for the sidebar's model task, bounded
        } while ContinuousClock.now < deadline
        #expect(sidebar.cardSlot.showsNotice, "the staged update card hides the agent's request")
    }
}
