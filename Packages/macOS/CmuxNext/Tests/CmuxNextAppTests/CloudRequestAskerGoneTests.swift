import AppKit
@testable import CmuxNextApp
import CmuxNextSettings
@testable import CmuxNextSidebar
import Foundation
import Observation
import Testing

/// An agent's Cloud machine request is only as live as the agent chat that asked: when that chat
/// closes, its sidebar card goes and the request answers no, so a later click can't create a
/// machine nobody waits for. A chat that stays open keeps its card; an asker this Mac shows no
/// chat for (another Mac's) never expires it.
@MainActor @Suite(.serialized) struct CloudRequestAskerGoneTests {
    /// The agent chats open on this Mac, observed like the window's tab tree.
    @MainActor @Observable final class Chats {
        var open: Set<String> = ["chat-1", "chat-2"]
    }

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

    /// Starts chat `chat`'s create and returns it once its card is up.
    func create(_ services: AppServices, in window: NSWindow, chats: Chats, asker chat: String, sent: Sent) async throws -> (Task<String, any Error>, SidebarNoticeCard) {
        let asks = services.machineAsks
        let task = Task {
            try await CloudMachineCreateFlow.legacy(name: "builder", startedByPerson: false, askedBy: chat, askFirst: true,
                                                    confirm: { await CloudPresenter.confirmCreate($0, in: window, asks: asks, chatOpen: { chats.open.contains($0) }) },
                                                    create: { sent.send() })
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while asks.card == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5)) // test-only: waits for the create's task, bounded
        }
        return (task, try #require(asks.card, "the agent's create asked nobody"))
    }

    /// Waits, bounded, until `services` shows no request card.
    func cardGone(_ services: AppServices) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while services.machineAsks.card != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5)) // test-only: the watch hops to the main actor, bounded
        }
        return services.machineAsks.card == nil
    }

    @Test func closingTheAskingChatTakesItsCardAndCreatesNothing() async throws {
        let (services, window) = make()
        defer { window.close() }
        let chats = Chats(), sent = Sent()
        let (task, card) = try await create(services, in: window, chats: chats, asker: "chat-1", sent: sent)

        chats.open.remove("chat-1")
        #expect(try await cardGone(services), "the closed chat's request still waits in the sidebar")
        await #expect(throws: CloudMachineCreateFlow.Failure.declined) { try await task.value }
        // The card's Create, clicked late, answers nothing and creates nothing.
        let create = try #require(card.actions.first { $0.prominent })
        SidebarCardFeed.handle(.noticeAction(card: card.id, action: create.id), services: services)
        #expect(sent.count == 0, "a request whose chat closed made a machine")
    }

    @Test(arguments: ["chat-1", "chat-on-another-mac"])
    func anOpenChatOrAnAskerWithNoChatHereKeepsTheCard(asker: String) async throws {
        let (services, window) = make()
        defer { window.close() }
        let chats = Chats(), sent = Sent()
        let (task, card) = try await create(services, in: window, chats: chats, asker: asker, sent: sent)

        chats.open.remove("chat-2") // another chat closing is not this asker going away
        try await Task.sleep(for: .milliseconds(50)) // test-only: lets a wrong expiry land
        #expect(services.machineAsks.card == card, "the request of \(asker) lost its card when another chat closed")

        let create = try #require(card.actions.first { $0.prominent })
        SidebarCardFeed.handle(.noticeAction(card: card.id, action: create.id), services: services)
        #expect(try await task.value == "machine")
        #expect(sent.count == 1)
    }
}
