import CmuxAgentCursor
@testable import CmuxNextApp
import CmuxNextControl
import Testing

/// `cmux browser … --agent NAME` draws as that agent's own cursor (its own
/// color and name tag), a drag carries its drop point, and a page scroll
/// with no selector still shows where it scrolled.
@MainActor
struct PageInputCursorEventsTests {
    @Test func eachAgentNameIsItsOwnSession() {
        #expect(PageInputCursorEvents.sessionID(agent: nil) == "cmux-browser-cli")
        #expect(PageInputCursorEvents.sessionID(agent: "  ") == "cmux-browser-cli")
        #expect(PageInputCursorEvents.sessionID(agent: "Claude") == "cmux-browser-cli:Claude")
        var events = PageInputCursorEvents()
        let click = BrowserPageAgentInput(kind: .click, rect: .init(x: 0, y: 0, width: 10, height: 10), agent: "Codex")
        #expect(events.event(for: click, tabID: "tab_1")?.0.sessionID == "cmux-browser-cli:Codex")
    }

    @Test func aDragGoesFromTheGrabToTheDrop() throws {
        var events = PageInputCursorEvents()
        let drag = BrowserPageAgentInput(kind: .drag, rect: .init(x: 0, y: 0, width: 20, height: 20),
                                         toRect: .init(x: 200, y: 100, width: 40, height: 40))
        let event = try #require(events.event(for: drag, tabID: "tab_1")?.0)
        #expect(event.kind == .drag)
        #expect(event.point == AutomationInputEvent.Point(x: 10, y: 10))
        #expect(event.to == AutomationInputEvent.Point(x: 220, y: 120))
    }

    @Test func aPageScrollDrawsAtTheMeasuredPoint() throws {
        var events = PageInputCursorEvents()
        let scroll = BrowserPageAgentInput(kind: .scroll, rect: .init(x: 400, y: 300, width: 0, height: 0))
        let event = try #require(events.event(for: scroll, tabID: "tab_1")?.0)
        #expect(event.kind == .scroll)
        #expect(event.point == AutomationInputEvent.Point(x: 400, y: 300))
    }

    @Test func sequenceNumbersStayGapFree() {
        var events = PageInputCursorEvents()
        let click = BrowserPageAgentInput(kind: .click, rect: .init(x: 0, y: 0, width: 1, height: 1))
        let seqs = (0..<3).compactMap { _ in events.event(for: click, tabID: "t")?.0.seq }
        #expect(seqs == [0, 1, 2])
    }
}
