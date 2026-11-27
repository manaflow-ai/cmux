import AppKit
import CmuxNextPages
import CmuxNextTestSupport
import Foundation
import Observation
import Testing
@testable import CmuxNextAgentPane

/// cmux#48660 (Austin, 2026-11-20): "making a Cloud workspace, it looks fine for a second, then the pane goes blank
/// with only a centered spinner, then eventually loads". A Cloud start keeps its tab's chat on screen until the
/// machine's page painted (``AgentPaneDrawFirst``): it waits for that page to be makeable, then for its paint, both
/// within one bound that outlasts the page's own last resort.
@Suite(.serialized, .closesItsWindows)
@MainActor
struct AgentPaneDrawFirstTests {
    @Observable @MainActor final class Flag { var on = false }
    @MainActor final class Count { var made = 0 }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static func page() throws -> (AgentPaneView, NSWindow) {
        _ = NSApplication.shared
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(URL(filePath: "/dev/null"))))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.orderFrontRegardless()
        return (view, window)
    }

    @Test func theBoundOutlastsThePagesOwnLastResortAndTheOld8Seconds() {
        // App.tsx CHAT_DRAW_HOLD_MS: the page reports its first paint by 10 s after its handshake, chat read or not.
        #expect(AgentPaneDrawFirst.bound > .seconds(10), "a slow page showed as the blank loading cover")
    }

    @Test func aConditionThatHoldsNowAnswersAtOnce() async {
        #expect(await AgentPaneDrawFirst.holds(within: .seconds(60)) { true })
    }

    @Test func aConditionThatComesToHoldEndsTheWait() async {
        let flag = Flag()
        let waiting = Task { await AgentPaneDrawFirst.holds(within: .seconds(60)) { flag.on } }
        try? await Task.sleep(for: .milliseconds(30)) // wakeup-allow: a test lets the wait begin first
        flag.on = true
        #expect(await waiting.value, "the wait did not end when the page became makeable")
    }

    @Test func aConditionThatNeverHoldsGivesUpAfterTheBound() async {
        let began = ContinuousClock.now
        #expect(await AgentPaneDrawFirst.holds(within: .milliseconds(50)) { false } == false)
        #expect(began.duration(to: .now) < .seconds(5), "the wait outlived its bound")
    }

    @Test func aPageMadeLateIsDrawnOutOfSightAndShowsOnceItPainted() async throws {
        let (view, window) = try Self.page()
        defer { window.close() }
        let flag = Flag()
        let count = Count()
        let drawing = Task {
            await AgentPaneDrawFirst.draw({ count.made += 1; return view }, makeable: { flag.on }, in: window,
                                          size: CGSize(width: 320, height: 240), within: .seconds(60))
        }
        try await Task.sleep(for: .milliseconds(30)) // wakeup-allow: a test lets the wait begin first
        #expect(count.made == 0, "the page was made before its tab could make it")
        flag.on = true
        try await Task.sleep(for: .milliseconds(50)) // wakeup-allow: a test lets the page park first
        #expect(count.made == 1)
        #expect(view.superview is PageOffscreenParking, "the late page was not drawn out of sight")
        view.model.markPainted()
        #expect(await drawing.value == .painted)
    }

    @Test func aPageNeverMakeableGivesUpAsNotMade() async throws {
        let (_, window) = try Self.page()
        defer { window.close() }
        let outcome = await AgentPaneDrawFirst.draw({ nil }, makeable: { false }, in: window, size: CGSize(width: 320, height: 240),
                                                    within: .milliseconds(50))
        #expect(outcome == .noPage)
    }

    @Test func aPageThatNeverPaintsShowsUnpaintedAfterTheBound() async throws {
        let (view, window) = try Self.page()
        defer { window.close() }
        let outcome = await AgentPaneDrawFirst.draw({ view }, makeable: { true }, in: window, size: CGSize(width: 320, height: 240),
                                                    within: .milliseconds(50))
        #expect(outcome == .unpainted)
    }

    @Test func eachOutcomeNamesItsOwnTimelineStep() {
        let names = AgentPaneDrawFirst.Outcome.allCases.map(\.rawValue)
        #expect(Set(names).count == names.count)
        for name in names { #expect(name.hasPrefix("page "), "\(name)") }
    }
}
