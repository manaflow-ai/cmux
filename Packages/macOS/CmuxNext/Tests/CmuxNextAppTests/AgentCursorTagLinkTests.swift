import CmuxAgentCursor
@testable import CmuxNextAgentCursor
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextDesign
import Foundation
import QuartzCore
import Testing

/// User, 2026-10-20: rename the tag from the generic "Claude" to who is
/// driving and where ("Chief · <workspace name>", "a201 · <workspace or
/// terminal title>"); on hover a pointer, a small highlight and the tooltip
/// "Go to <workspace>"; a click focuses that workspace and pane; VoiceOver
/// gets the same.
@MainActor
struct AgentCursorTagLinkTests {
    final class Visible: AgentCursorTargetResolving {
        func placement(forTarget targetID: String) -> AgentCursorPlacement {
            .visible(content: CGRect(x: 0, y: 0, width: 800, height: 600), clip: CGRect(x: 0, y: 0, width: 800, height: 600),
                     zoom: 1, magnification: 1)
        }
    }

    static let agent = BrowserPageAgentOrigin(isChief: false, workspaceID: "ws_1", workspaceName: "cursor-gallery", tabID: "tab_term")
    static let chief = BrowserPageAgentOrigin(isChief: true, workspaceID: "ws_home", workspaceName: "Home", tabID: "tab_chat")

    struct Case: Sendable {
        var driver: String
        var place: String?
        var text: String
    }

    @Test(arguments: [
        Case(driver: "a201", place: "cursor-gallery", text: "a201 · cursor-gallery"),
        Case(driver: "Chief", place: "Home", text: "Chief · Home"),
        Case(driver: "Claude", place: nil, text: "Claude"),
        Case(driver: "Claude", place: "  ", text: "Claude"),
    ])
    func theTagSaysWhoDrivesAndWhere(_ given: Case) {
        #expect(AgentCursorTagLabel(driver: given.driver, place: given.place).text == given.text)
    }

    @Test func aLongPlaceIsCutNeverTheDriver() {
        let text = AgentCursorTagLabel(driver: "a201", place: "a very long workspace name that goes on and on").text
        #expect(text.hasPrefix("a201 · a very"))
        #expect(text.hasSuffix("…"))
        #expect(text.count == AgentCursorTagLabel.maxLength)
    }

    @Test func eachCallerIsItsOwnCursor() {
        #expect(PageInputCursorEvents.sessionID(agent: "Claude", origin: Self.agent) == "cmux-browser-cli:Claude|tab_term")
        #expect(PageInputCursorEvents.sessionID(agent: "Claude", origin: Self.chief) != PageInputCursorEvents.sessionID(agent: "Claude", origin: Self.agent),
                "two Claude agents in two workspaces draw two cursors")
        #expect(PageInputCursorEvents.sessionID(agent: "Claude", origin: nil) == "cmux-browser-cli:Claude")
        #expect(AgentCursorSessionLabel(sessionID: "cmux-browser-cli:Claude|tab_term").text == "Claude", "the fallback name drops the caller key")
        var events = PageInputCursorEvents()
        let click = BrowserPageAgentInput(kind: .click, rect: .init(x: 0, y: 0, width: 10, height: 10), agent: "a201", origin: Self.agent)
        #expect(events.event(for: click, tabID: "tab_page")?.0.sessionID == "cmux-browser-cli:a201|tab_term")
    }

    private func setUp(_ reveal: @escaping (String) -> Bool) -> (AgentCursorTagLinks, AgentCursorStack, AgentCursorWindowTags) {
        let links = AgentCursorTagLinks(reveal: reveal)
        // Reduce Transparency pinned off: under the shared one's `override` (set by suites that run
        // alongside) the tag is opaque at rest and on hover, so the highlight would not show.
        let stack = AgentCursorStack(hostLayer: CALayer(), resolver: Visible(), label: { links.label(for: $0) },
                                     reduceTransparency: ReduceTransparency(system: { false }, changes: NotificationCenter()))
        return (links, stack, AgentCursorWindowTags(links: links, host: { stack.host }))
    }

    @Test func theTagNamesTheDriverAndTheWorkspace() throws {
        let (links, stack, tags) = setUp { _ in true }
        links.note(Self.agent, agent: "a201", session: "s1")
        links.note(Self.chief, agent: "Claude", session: "s2")
        stack.host.apply(.place(session: "s1", point: CGPoint(x: 100, y: 100)))
        stack.host.apply(.place(session: "s2", point: CGPoint(x: 300, y: 200)))
        #expect(stack.host.cursorLayer(for: "s1")?.tagText == "a201 · cursor-gallery")
        #expect(stack.host.cursorLayer(for: "s2")?.tagText == "Chief · Home", "a Chief turn reads Chief, not Claude")
        let shown = tags.agentCursorTags().sorted { $0.id < $1.id }
        #expect(shown.map(\.label) == ["a201 · cursor-gallery", "Chief · Home"])
        #expect(shown.map(\.help) == ["Go to cursor-gallery", "Go to Home"])
        let cursor = try #require(stack.host.cursorLayer(for: "s1"))
        #expect(shown[0].frame == cursor.nameTag.frame.offsetBy(dx: 100, dy: 100), "the tag's frame in the cursor layer")
    }

    @Test func aClickOnTheTagGoesToTheAgentsTab() {
        var revealed: [String] = []
        let (links, stack, tags) = setUp { revealed.append($0); return true }
        links.note(Self.agent, agent: "a201", session: "s1")
        stack.host.apply(.place(session: "s1", point: CGPoint(x: 100, y: 100)))
        tags.pressAgentCursorTag("s1")
        #expect(revealed == ["tab_term"], "the workspace and pane of the agent's terminal")
        tags.pressAgentCursorTag("unknown")
        #expect(revealed == ["tab_term"])
    }

    @Test func aCursorWithoutAnOriginIsNoLink() {
        let (_, stack, tags) = setUp { _ in true }
        stack.host.apply(.place(session: "cmux-browser-cli:Claude", point: CGPoint(x: 100, y: 100)))
        #expect(stack.host.cursorLayer(for: "cmux-browser-cli:Claude")?.tagText == "Claude")
        #expect(tags.agentCursorTags().isEmpty)
    }

    @Test func hiddenCursorsHaveNoTagToClick() {
        let (links, stack, tags) = setUp { _ in true }
        links.note(Self.agent, agent: "a201", session: "s1")
        stack.host.apply(.place(session: "s1", point: CGPoint(x: 100, y: 100)))
        stack.host.apply(.hide(session: "s1"))
        #expect(tags.agentCursorTags().isEmpty)
        stack.host.apply(.indicate(session: "s1", anchor: CGPoint(x: 5, y: 5)))
        #expect(tags.agentCursorTags().isEmpty, "the hidden-target dot has no tag")
    }

    @Test func hoverHighlightsTheTag() throws {
        let (links, stack, tags) = setUp { _ in true }
        links.note(Self.agent, agent: "a201", session: "s1")
        stack.host.apply(.place(session: "s1", point: CGPoint(x: 100, y: 100)))
        let cursor = try #require(stack.host.cursorLayer(for: "s1"))
        let resting = cursor.nameTag.backgroundColor
        tags.hoverAgentCursorTag("s1")
        #expect(cursor.isTagHighlighted)
        #expect(cursor.nameTag.backgroundColor != resting)
        tags.hoverAgentCursorTag(nil)
        #expect(!cursor.isTagHighlighted)
        #expect(cursor.nameTag.backgroundColor == resting)
    }
}
