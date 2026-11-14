import AppKit
import CmuxNextSettings
@testable import CmuxNextPages
import Testing

/// Two-finger Back / Forward over a page: the host only forwards. A trackpad event maps to the page's
/// `SwipeEvent` fields unjudged (a mouse wheel maps to nothing), the router carries it on the built-in
/// `cmux.page.swipe` stream, and the page's commit and release reach the host's closures.
@MainActor @Suite
struct PageSwipeForwardingTests {
    static let descriptor = PageDescriptor(id: "cmux.swipe-test", resource: "swipe-test", namespaces: ["cmux.swipe."])

    @Test func phasesMapAsThePageNamesThem() throws {
        func map(_ phase: NSEvent.Phase, momentum: NSEvent.Phase = []) -> PageSwipeEvent? {
            PageSwipeEvent(phase: phase, momentumPhase: momentum, dx: 3, dy: -1, precise: true, inverted: true, timestamp: 2)
        }
        #expect(map(.mayBegin)?.phase == "mayBegin")
        #expect(map(.began)?.phase == "began")
        #expect(map(.changed)?.phase == "changed")
        #expect(map(.ended)?.phase == "ended")
        #expect(map(.cancelled)?.phase == "cancelled")
        let momentum = try #require(map([], momentum: .began))
        #expect(momentum.momentum && momentum.phase == "began" && !momentum.starts)
        #expect(map(.began)?.starts == true)
        #expect(map(.began)?.time == 2000)
        // A mouse wheel: no phase, or no precise deltas.
        #expect(map([]) == nil)
        #expect(PageSwipeEvent(phase: .began, momentumPhase: [], dx: 1, dy: 0, precise: false, inverted: true, timestamp: 0) == nil)
    }

    @Test func theRouterCarriesSwipesAndThePageAnswers() async throws {
        let router = PageRouter(descriptor: Self.descriptor, routes: [])
        var sent: [JSONValue] = []
        router.send = { sent.append($0) }
        #expect(!router.hasSwipeSubscriber)
        let reply = await router.handle(["t": "sub", "id": 1, "stream": .string(PageNativeOp.pageSwipe)])
        #expect(reply["t"]?.stringValue == "ok", "\(reply)")
        #expect(router.hasSwipeSubscriber)
        let event = try #require(PageSwipeEvent(phase: .began, momentumPhase: [], dx: 4, dy: 0, precise: true,
                                                inverted: false, timestamp: 1))
        router.publishSwipe(event.json(gesture: 7, back: true, forward: false))
        let data = try #require(sent.last?["data"])
        #expect(data["phase"]?.stringValue == "began" && data["g"]?.doubleValue == 7)
        #expect(data["back"]?.boolValue == true && data["forward"]?.boolValue == false && data["inverted"]?.boolValue == false)

        var navigated: [Bool] = []
        router.historyNavigate = { back, gesture in navigated.append(back); return gesture == 7 }
        let answer = await router.handle(["t": "call", "id": 2, "op": .string(PageNativeOp.historyNavigate), "params": ["back": true, "g": 7]])
        #expect(answer["value"]?["navigated"]?.boolValue == true && navigated == [true])
        // A commit must name its gesture.
        let unnamed = await router.handle(["t": "call", "id": 4, "op": .string(PageNativeOp.historyNavigate), "params": ["back": true]])
        #expect(unnamed["t"]?.stringValue != "ok" && navigated == [true], "\(unnamed)")
        var released: [Int] = []
        router.swipeRelease = { released.append($0) }
        _ = await router.handle(["t": "call", "id": 3, "op": .string(PageNativeOp.swipeRelease), "params": ["g": 7]])
        #expect(released == [7])
    }

    /// Only the live gesture's page may run Back / Forward, once, soon after its last event
    /// (review F2 at c0da1520: a page could run it after its gesture ended, or from a stale page).
    @Test func onlyTheLiveGestureCommitsAndOnlyOnce() {
        let pages = (NSObject(), NSObject())
        let page = ObjectIdentifier(pages.0)
        let other = ObjectIdentifier(pages.1)
        var gate = PageSwipeCommitGate()
        let taken1 = gate.take(page: page, gesture: 1, at: 0)
        #expect(!taken1, "nothing forwarded yet")
        gate.open(page: page, gesture: 3, at: 10)
        let taken2 = gate.take(page: other, gesture: 3, at: 10.1)
        #expect(!taken2, "another page")
        let taken3 = gate.take(page: page, gesture: 2, at: 10.1)
        #expect(!taken3, "an earlier gesture")
        let taken4 = gate.take(page: page, gesture: 3, at: 10.2)
        #expect(taken4)
        let taken5 = gate.take(page: page, gesture: 3, at: 10.3)
        #expect(!taken5, "a second commit of the same gesture")
        gate.open(page: page, gesture: 4, at: 20)
        gate.touch(at: 21)
        let taken6 = gate.take(page: page, gesture: 4, at: 21 + PageSwipeCommitGate.window + 0.1)
        #expect(!taken6, "too long after its last event")
    }
}
