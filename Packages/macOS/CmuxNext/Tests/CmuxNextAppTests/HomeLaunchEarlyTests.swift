import AppKit
import CmuxHomeCore
@testable import CmuxNextHome
import Foundation
import Testing

/// A bare launch's message box in stage 0's first frame: the real window's page takes over its
/// store and hold, so what was typed and sent there is the page's; stage 0's swap waits for the
/// real box; a launch with no page gives it all to the Chief. Nothing typed is dropped.
@MainActor @Suite(.serialized)
struct HomeLaunchEarlyTests {
    static let launch = HomeLaunchChiefSource.conversation
    static let chief = ConversationID("conv_chief")
    static let frame = CGRect(x: 0, y: 0, width: 600, height: 400)

    @Test func thePageTakesStage0sTextAndHeldSends() async throws {
        defer { _ = HomeLaunchEarly.adopt() }
        let marks = Marks()
        let view = HomeLaunchEarly.start(title: "Chief", frame: Self.frame) { marks.add($0) }
        #expect(view.frame == Self.frame)
        #expect(marks.all == ["home.launch_early"])
        let early = try #require(HomeLaunchEarly.current)
        early.store.setDraft("typed in stage 0", for: Self.launch)
        let send = Task { try await early.hold.hold([.text("sent in stage 0")], key: .make()) }
        for _ in 0..<100 where early.hold.heldParts.isEmpty { await Task.yield() }
        let home = HomeLaunchChiefTests.store(LaunchChiefHold())
        home.start()
        defer { home.stop() }
        let page = HomeLaunchComposer(home: home, me: HomeLaunchChiefTests.me, title: "Chief") { _ in NSView() }
        #expect(page.store === early.store)
        #expect(page.hold === early.hold)
        #expect(page.store.draft(for: Self.launch) == "typed in stage 0")
        #expect(page.hold.heldParts == [[.text("sent in stage 0")]])
        #expect(HomeLaunchEarly.current == nil)
        page.hold.resolve(Self.chief) { _, _, _ in }
        _ = try await send.value
        page.end()
    }

    @Test func aParkedDraftGoesAfterStage0sText() async throws {
        defer { _ = HomeLaunchEarly.adopt() }
        _ = HomeLaunchEarly.start(title: "Chief", frame: Self.frame) { _ in }
        let early = try #require(HomeLaunchEarly.current)
        early.store.setDraft("new", for: Self.launch)
        let home = HomeLaunchChiefTests.store(LaunchChiefHold())
        home.start()
        defer { home.stop() }
        home.setDraft("kept from the last quit", for: Self.launch)
        let page = HomeLaunchComposer(home: home, me: HomeLaunchChiefTests.me, title: "Chief") { _ in NSView() }
        #expect(page.store.draft(for: Self.launch) == "new\nkept from the last quit")
        #expect(home.draft(for: Self.launch) == nil)
        page.end()
    }

    @Test func theSwapWaitsForTheRealBox() async throws {
        defer { _ = HomeLaunchEarly.adopt() }
        _ = HomeLaunchEarly.start(title: "Chief", frame: Self.frame) { _ in }
        var swapped = 0
        HomeLaunchEarly.whenUp { swapped += 1 }
        #expect(swapped == 0)
        // A box focus before any page took the launch is not Home's page: still waiting.
        HomeLaunchEarly.boxIsUp()
        #expect(swapped == 0)
        let home = HomeLaunchChiefTests.store(LaunchChiefHold())
        home.start()
        defer { home.stop() }
        let page = HomeLaunchComposer(home: home, me: HomeLaunchChiefTests.me, title: "Chief") { _ in NSView() }
        #expect(swapped == 0)
        HomeLaunchEarly.boxIsUp()
        #expect(swapped == 1)
        HomeLaunchEarly.boxIsUp()
        #expect(swapped == 1)
        // Asked after the box was up: at once.
        HomeLaunchEarly.whenUp { swapped += 1 }
        #expect(swapped == 2)
        page.end()
    }

    @Test func withNoPageTheChiefTakesTheTextAndSends() async throws {
        defer { _ = HomeLaunchEarly.adopt() }
        _ = HomeLaunchEarly.start(title: "Chief", frame: Self.frame) { _ in }
        let early = try #require(HomeLaunchEarly.current)
        early.store.setDraft("typed", for: Self.launch)
        let key = IdempotencyKey.make()
        let send = Task { try await early.hold.hold([.text("sent")], key: key) }
        for _ in 0..<100 where early.hold.heldParts.isEmpty { await Task.yield() }
        var swapped = false
        HomeLaunchEarly.whenUp { swapped = true }
        let home = HomeLaunchChiefTests.store(LaunchChiefHold())
        home.start()
        defer { home.stop() }
        home.setDraft("mine", for: Self.chief)
        HomeLaunchComposer.claimParked(to: Self.chief, in: home)
        #expect(home.draft(for: Self.chief) == "mine\ntyped")
        #expect(early.hold.chief == Self.chief)
        #expect(swapped)
        #expect(HomeLaunchEarly.current == nil)
        let answer = try await send.value
        #expect(answer.conversation == Self.chief)
    }
}

@MainActor
private final class Marks {
    private(set) var all: [String] = []
    func add(_ mark: String) { all.append(mark) }
}
