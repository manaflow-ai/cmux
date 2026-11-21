import AppKit
import CmuxNextPagesTestSupport
import CmuxNextTestSupport
import Testing
@testable import CmuxNextAgentPane
@testable import CmuxNextPages

/// A chat tab switched away from and back keeps its laid-out frame (Leo, 2026-11-15: "there is layout shift
/// here... why..."): its Chromium page is never told it is hidden, keeps its size, and reads as hidden to the
/// document. Detector for the class "a hidden page drops its frame and redraws on return" (cmuxterm-hq
/// docs/handbook/hidden-page-keeps-its-frame.md), with the frame-judged tab-switch/v1 harness
/// (scripts/measure/tab-switch.sh: 0 blank frames, 0 px shift).
@Suite(.serialized, .closesItsWindows)
@MainActor
struct AgentPageDrawnParkingTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static let size = NSRect(x: 0, y: 0, width: 800, height: 600)

    /// A painted chat in Chromium, shown in `host` of a window.
    private func chat() async throws -> (AgentPaneView, FakeChromiumPage, NSWindow, NSView) {
        _ = NSApplication.shared
        let file = try #require(AgentPageTestRoot.page)
        let hosting = FakeChromiumHosting()
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file),
                                              pageHost: true, chromium: hosting))
        let page = try #require(view.page)
        await page.chromiumStart?.value
        let chromium = try #require(hosting.made.first)
        let window = NSWindow(contentRect: Self.size, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: Self.size)
        window.contentView = host
        view.frame = host.bounds
        host.addSubview(view)
        view.loadingView.leave(over: view.pageContent, fades: false)
        view.model.markPainted()
        return (view, chromium, window, host)
    }

    /// K switches away and back: the page is never hidden to Chromium (no blank frame on return), keeps its size
    /// (0 px shift), and is away to the document only while no pane shows it.
    @Test func aChatSwitchedAwayAndBackStaysDrawnAtItsSize() async throws {
        let (view, chromium, window, host) = try await chat()
        defer { view.page?.close(); window.close() }
        let start = chromium.visibility.count
        for round in 0..<8 {
            #expect(AgentPageDrawnParking.park(view), "round \(round): a painted Chromium chat was not kept drawn")
            #expect(view.page?.isDrawnAway == true)
            #expect(!view.isHiddenOrHasHiddenAncestor)
            #expect(!view.isShownToPerson, "round \(round): a chat waiting off screen still counts as shown (question keys, dialogs, held keys)")
            #expect(view.frame.size == Self.size.size, "round \(round): the parked chat changed size (it lays out again on return)")
            guard case .drawn = AgentPageDrawnParking.takeBack(view) else {
                Issue.record("round \(round): the chat did not come back drawn")
                return
            }
            host.addSubview(view)
            view.frame = host.bounds
            #expect(view.page?.isDrawnAway == false)
            #expect(view.isShownToPerson)
        }
        #expect(!chromium.visibility.dropFirst(start).contains(false), "a switch told Chromium the chat is hidden: it drops its frame")
        #expect(AgentPageDrawnParking.of(window)?.drawnCount == 0)
    }

    /// Bounded per window: past ``AgentPageDrawnParking/limit`` the oldest goes hidden, its last frame pictured,
    /// and its return hands that picture to the pane.
    @Test func pastTheLimitTheOldestGoesHiddenWithItsPicture() async throws {
        var chats: [(AgentPaneView, FakeChromiumPage, NSWindow, NSView)] = []
        for _ in 0...AgentPageDrawnParking.limit { chats.append(try await chat()) }
        let (_, _, window, host) = chats[0]
        defer { for chat in chats { chat.0.page?.close(); chat.2.close() } }
        for chat in chats.dropFirst() {
            chat.0.removeFromSuperview()
            chat.0.frame = host.bounds
            host.addSubview(chat.0)
        }
        let picture = NSImage(size: Self.size.size)
        #expect(AgentPageDrawnParking.park(chats[0].0))
        let keeper = try #require(AgentPageDrawnParking.of(window))
        keeper.snapshotOverride = { _ in picture }
        for chat in chats.dropFirst() { #expect(AgentPageDrawnParking.park(chat.0)) }
        let oldest = chats[0].0
        for _ in 0..<100 where !oldest.isHidden { await Task.yield() }
        #expect(oldest.isHidden, "the oldest chat past the window's limit kept drawing")
        #expect(chats[0].1.visibility.last == false)
        #expect(keeper.drawnCount == AgentPageDrawnParking.limit)
        #expect(oldest.window === window)
        guard case .hidden(let cover) = AgentPageDrawnParking.takeBack(oldest) else {
            Issue.record("a chat gone hidden came back as drawn")
            return
        }
        #expect(cover === picture, "the chat gone hidden lost its last frame")
    }

    /// A picture that never comes (a hung renderer) does not keep the chat drawn past the limit: past
    /// ``AgentPageDrawnParking/pictureDeadline`` it goes hidden with no picture, so the window's drawn count stays bounded.
    @Test func aPictureThatNeverComesStillHidesTheChat() async throws {
        var chats: [(AgentPaneView, FakeChromiumPage, NSWindow, NSView)] = []
        for _ in 0...AgentPageDrawnParking.limit { chats.append(try await chat()) }
        let (_, _, window, host) = chats[0]
        defer { for chat in chats { chat.0.page?.close(); chat.2.close() } }
        for chat in chats.dropFirst() {
            chat.0.removeFromSuperview()
            chat.0.frame = host.bounds
            host.addSubview(chat.0)
        }
        #expect(AgentPageDrawnParking.park(chats[0].0))
        let keeper = try #require(AgentPageDrawnParking.of(window))
        keeper.snapshotOverride = { _ in
            try? await Task.sleep(for: .seconds(30))
            return NSImage(size: Self.size.size)
        }
        for chat in chats.dropFirst() { #expect(AgentPageDrawnParking.park(chat.0)) }
        let oldest = chats[0].0
        let clock = ContinuousClock()
        let end = clock.now + AgentPageDrawnParking.pictureDeadline + .seconds(3)
        while !oldest.isHidden, clock.now < end { try await Task.sleep(for: .milliseconds(50)) }
        #expect(oldest.isHidden, "a chat whose picture never came kept drawing off screen")
        guard case .hidden(let cover) = AgentPageDrawnParking.takeBack(oldest) else {
            Issue.record("a chat gone hidden came back as drawn")
            return
        }
        #expect(cover == nil)
    }

    /// A chat that leaves the keep by another path (its tab closed while it waited, and the closed-tab retirer moved it;
    /// Reopen Closed brings it back from there) is no longer away to its document.
    @Test func aChatMovedOutOfTheKeepIsNoLongerAway() async throws {
        let (view, _, window, host) = try await chat()
        defer { view.page?.close(); window.close() }
        #expect(AgentPageDrawnParking.park(view))
        #expect(view.page?.isDrawnAway == true)
        let elsewhere = NSView(frame: Self.size)
        host.addSubview(elsewhere)
        elsewhere.addSubview(view)
        #expect(view.page?.isDrawnAway == false, "a chat moved out of the keep stayed hidden to its document")
    }

    /// A New Tab page, or a chat that never painted, is not kept: the pane hides it as before.
    @Test func onlyPaintedChatsAreKept() async throws {
        let (view, _, window, _) = try await chat()
        defer { view.page?.close(); window.close() }
        view.isHidden = true
        #expect(!AgentPageDrawnParking.park(view), "a hidden chat was moved")
        #expect(AgentPageDrawnParking.of(window) == nil)
    }
}
