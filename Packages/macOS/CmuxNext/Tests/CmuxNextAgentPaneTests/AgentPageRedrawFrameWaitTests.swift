import AppKit
import CmuxNextPages
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// ``AgentPageRedraw/afterNextFrame(_:)``: only the page's frame callback keeps the
/// waiting bodies. A page that drops its callback releases them, so the New Tab capture's
/// `OnceContinuation` ends abandoned instead of hanging its task, and the next wait asks again.
@MainActor
struct AgentPageRedrawFrameWaitTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// An agent page; the redraw under test reaches it only through `nextFrame`.
    private static func page() throws -> AgentPaneView {
        let file = try #require(AgentPageTestRoot.page)
        return try #require(AgentPaneView(mainThread: .standalone(), model: AgentPaneModel(host: NoHost()), work: BackgroundWork(label: "test.agent-pane"),
                                          source: .bundled(file), webUI: .agentPaneTestHost(), gestures: .testing()))
    }

    /// What a waiting body holds: the New Tab capture's continuation stands for it.
    private final class Held {}

    /// The page answers its frame wait: one callback for every body that waited meanwhile.
    private final class FramePage {
        var asked = 0
        var dropsCallbacks = true
        var kept: [() -> Void] = []

        func nextFrame(_ page: PageWebView, _ body: @escaping () -> Void) {
            asked += 1
            if !dropsCallbacks { kept.append(body) }
        }
    }

    @Test func aFrameCallbackThePageDropsReleasesTheWaitersAndTheNextWaitAsksAgain() throws {
        let view = try Self.page()
        let page = FramePage()
        let redraw = AgentPageRedraw(page: view.page) { page.nextFrame($0, $1) }
        weak var released: Held?
        var ran = 0
        do {
            let held = Held()
            released = held
            redraw.afterNextFrame { withExtendedLifetime(held) { ran += 1 } }
        }
        #expect(page.asked == 1)
        #expect(released == nil, "the redraw kept a body the page dropped: its continuation never ends")
        #expect(ran == 0)

        page.dropsCallbacks = false
        redraw.afterNextFrame { ran += 1 }
        redraw.afterNextFrame { ran += 1 }
        #expect(page.asked == 2, "a dropped wait left the redraw waiting for ever: no later frame was asked")
        let callbacks = page.kept
        page.kept = []
        callbacks.forEach { $0() }
        #expect(ran == 2)

        redraw.afterNextFrame { ran += 1 }
        #expect(page.asked == 3, "an answered wait asks for the next frame again")
    }
}
