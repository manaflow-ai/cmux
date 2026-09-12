import Foundation
import Testing
@testable import CmuxBrowser

@MainActor
@Suite("Chromium navigation ticket completion")
struct ChromiumNavigationCompletionTests {
    @Test("CDP completion only finishes the exact active ticket")
    func exactTicket() async {
        let coordinator = BrowserAutomationNavigationCoordinator()
        let instance = UUID()
        coordinator.bind(to: instance)
        let stale = coordinator.begin(instanceID: instance)
        let current = coordinator.begin(instanceID: instance)
        coordinator.finishExternally(stale, with: .committed)
        coordinator.finishExternally(current, with: .failed("navigation rejected"))
        #expect(await coordinator.wait(for: stale) == .superseded)
        #expect(await coordinator.wait(for: current) == .failed("navigation rejected"))
    }

    @Test("A replacement browser instance supersedes pending CDP completion")
    func replacedInstance() async {
        let coordinator = BrowserAutomationNavigationCoordinator()
        let instance = UUID()
        coordinator.bind(to: instance)
        let ticket = coordinator.begin(instanceID: instance)
        coordinator.bind(to: UUID())
        coordinator.finishExternally(ticket, with: .committed)
        #expect(await coordinator.wait(for: ticket) == .superseded)
    }
}
