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
        router.historyNavigate = { navigated.append($0); return true }
        let answer = await router.handle(["t": "call", "id": 2, "op": .string(PageNativeOp.historyNavigate), "params": ["back": true]])
        #expect(answer["value"]?["navigated"]?.boolValue == true && navigated == [true])
        var released: [Int] = []
        router.swipeRelease = { released.append($0) }
        _ = await router.handle(["t": "call", "id": 3, "op": .string(PageNativeOp.swipeRelease), "params": ["g": 7]])
        #expect(released == [7])
    }
}
