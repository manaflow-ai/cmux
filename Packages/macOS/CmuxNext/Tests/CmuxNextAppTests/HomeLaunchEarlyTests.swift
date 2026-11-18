import AppKit
import CmuxHomeCore
@testable import CmuxNextHome
import Foundation
import Testing

/// A bare launch's message box in stage 0's first frame: the real window's page takes over its
/// store and hold, so what was typed and sent there is the page's; stage 0's swap waits for the
/// real box; a launch with no page gives it all to the Chief; a quit before either keeps the text.
@MainActor @Suite
struct HomeLaunchEarlyTests {
    static let launch = HomeLaunchChiefSource.conversation
    static let chief = ConversationID("conv_chief")
    static let frame = CGRect(x: 0, y: 0, width: 600, height: 400)

    @Test func thePageTakesStage0sTextAndHeldSends() async throws {
        let marks = Marks()
        let early = HomeLaunchEarly(title: { "Chief" }, panels: { [] }) { marks.add($0) }
        let view = early.start(frame: Self.frame)
        #expect(view.frame == Self.frame)
        #expect(marks.all == ["home.launch_early"])
        let box = try #require(early.box)
        box.store.setDraft("typed in stage 0", for: Self.launch)
        let send = Task { try await box.hold.hold([.text("sent in stage 0")], key: .make()) }
        for _ in 0..<100 where box.hold.heldParts.isEmpty { await Task.yield() }
        let home = Self.home()
        defer { home.stop() }
        let page = HomeLaunchComposer(home: home, me: HomeLaunchChiefTests.me, title: "Chief", early: early) { _ in NSView() }
        #expect(page.store === box.store)
        #expect(page.hold === box.hold)
        #expect(page.store.draft(for: Self.launch) == "typed in stage 0")
        #expect(page.hold.heldParts == [[.text("sent in stage 0")]])
        #expect(early.box == nil)
        page.hold.resolve(Self.chief) { _, _, _ in }
        _ = try await send.value
        page.end()
    }

    @Test func aParkedDraftGoesAfterStage0sText() async throws {
        let early = HomeLaunchEarly(title: { "Chief" }, panels: { [] }) { _ in }
        _ = early.start(frame: Self.frame)
        try #require(early.box).store.setDraft("new", for: Self.launch)
        let home = Self.home()
        defer { home.stop() }
        home.setDraft("kept from the last quit", for: Self.launch)
        let page = HomeLaunchComposer(home: home, me: HomeLaunchChiefTests.me, title: "Chief", early: early) { _ in NSView() }
        #expect(page.store.draft(for: Self.launch) == "new\nkept from the last quit")
        #expect(home.draft(for: Self.launch) == nil)
        page.end()
    }

    @Test func theSwapWaitsForTheRealBox() async throws {
        let early = HomeLaunchEarly(title: { "Chief" }, panels: { [] }) { _ in }
        _ = early.start(frame: Self.frame)
        var swapped = 0
        early.whenUp { swapped += 1 }
        #expect(swapped == 0)
        // A box focus before any page took the launch is not Home's page: still waiting.
        early.boxIsUp()
        #expect(swapped == 0)
        let home = Self.home()
        defer { home.stop() }
        let page = HomeLaunchComposer(home: home, me: HomeLaunchChiefTests.me, title: "Chief", early: early) { _ in NSView() }
        #expect(swapped == 0)
        early.boxIsUp()
        #expect(swapped == 1)
        early.boxIsUp()
        #expect(swapped == 1)
        // Asked after the box was up: at once.
        early.whenUp { swapped += 1 }
        #expect(swapped == 2)
        page.end()
    }

    @Test func withNoPageTheChiefTakesTheTextAndSends() async throws {
        let early = HomeLaunchEarly(title: { "Chief" }, panels: { [] }) { _ in }
        _ = early.start(frame: Self.frame)
        let box = try #require(early.box)
        box.store.setDraft("typed", for: Self.launch)
        let send = Task { try await box.hold.hold([.text("sent")], key: .make()) }
        for _ in 0..<100 where box.hold.heldParts.isEmpty { await Task.yield() }
        var swapped = false
        early.whenUp { swapped = true }
        let home = Self.home()
        defer { home.stop() }
        home.setDraft("mine", for: Self.chief)
        HomeLaunchComposer.claimParked(to: Self.chief, in: home, early: early)
        #expect(home.draft(for: Self.chief) == "mine\ntyped")
        #expect(box.hold.chief == Self.chief)
        #expect(swapped)
        #expect(early.box == nil)
        let answer = try await send.value
        #expect(answer.conversation == Self.chief)
    }

    @Test func aQuitBeforeAnyPageKeepsStage0sText() async throws {
        let early = HomeLaunchEarly(title: { "Chief" }, panels: { [] }) { _ in }
        _ = early.start(frame: Self.frame)
        let box = try #require(early.box)
        box.store.setDraft("typed", for: Self.launch)
        let send = Task { try await box.hold.hold([.text("held")], key: .make()) }
        for _ in 0..<100 where box.hold.heldParts.isEmpty { await Task.yield() }
        let home = Self.home()
        defer { home.stop() }
        early.saveForQuit(in: home)
        #expect(home.draft(for: Self.launch) == "held\ntyped")
        // A quit can be cancelled: the box goes on holding its send.
        #expect(box.hold.heldParts == [[.text("held")]])
        box.hold.resolve(Self.chief) { _, _, _ in }
        _ = try await send.value
    }

    /// Stage 0 draws the header toggles it is given (the page's, off), so the swap moves none.
    @Test func stage0ShowsThePagesHeaderToggles() throws {
        let item = HomeHeaderPanelItem(id: "screenShare", symbol: "display", onSymbol: "record.circle", label: "Share Screen", isOn: false)
        let early = HomeLaunchEarly(title: { "Chief" }, panels: { [item] }) { _ in }
        let transcript = try #require(HomeNativeTranscriptView.first(in: early.start(frame: Self.frame)))
        #expect(transcript.headerPanelItems == [item])
    }

    static func home() -> HomeStore {
        let home = HomeLaunchChiefTests.store(LaunchChiefHold())
        home.start()
        return home
    }
}

@MainActor
private final class Marks {
    private(set) var all: [String] = []
    func add(_ mark: String) { all.append(mark) }
}
