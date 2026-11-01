import CoreGraphics
import Testing
@testable import CmuxNextAgentPane

/// A window of a chat and the column on its right, as the app measures it (`RightColumn`): a pane
/// whose last tab closes goes away, so its split collapses.
@MainActor
final class RightColumnWindow {
    var chatWidth: CGFloat = 1400
    var rightWidth: CGFloat = 700
    /// The right column's panes, top to bottom, while they hold a tab.
    private var column: [String] = []
    /// Tab key to pane; the chat is in `chat`.
    var paneOf: [String: String] = ["chat": "chat"]
    var events: [String] = []
    private var panes = 0

    /// A pane already on the right of the chat (a diff, a terminal), holding tab `key`.
    func occupy(_ key: String) {
        panes += 1
        let pane = "right\(panes)"
        column.append(pane)
        paneOf[key] = pane
    }

    func close(_ key: String) { paneOf[key] = nil }

    /// The right column's panes that still hold a tab.
    var live: [String] { column.filter { pane in paneOf.values.contains(pane) } }

    var measured: RightColumnPlacement.Column {
        let live = live
        return .init(sourceWidth: chatWidth, panes: live, widths: Dictionary(uniqueKeysWithValues: live.map { ($0, rightWidth) }))
    }

    /// Opens tab `key` where `decision` says; returns the pane it lands in.
    @discardableResult
    func place(_ decision: RightColumnPlacement.Decision<String>, key: String) -> String {
        column = live
        let pane: String
        switch decision {
        case .splitRight:
            panes += 1
            pane = "right\(panes)"
            column = [pane]
            events.append("split right")
        case .splitBelow(let above):
            panes += 1
            pane = "right\(panes)"
            column.insert(pane, at: (column.firstIndex(of: above) ?? column.count - 1) + 1)
            events.append("split below \(above)")
        case .tab(let target):
            pane = target ?? "chat"
            events.append("tab in \(pane)")
        }
        paneOf[key] = pane
        return pane
    }
}

/// leo-workspace design/pane-placement.md. Leo 2026-10-30: "subagent stuff... or anything we expect
/// to open on "the right"... if there's already a thing on the right, there should be logic for just
/// putting it on the lower pane of the right. that kinda split."
@Suite
struct RightColumnPlacementTests {
    private typealias Rule = RightColumnPlacement

    @Test func nothingOnTheRightSplitsRight() {
        #expect(Rule.decide(.init(sourceWidth: 1400)) == .splitRight)
    }

    @Test func somethingOnTheRightSplitsBelowIt() {
        #expect(Rule.decide(.init(sourceWidth: 1400, panes: ["diff"], widths: ["diff": 700])) == .splitBelow("diff"))
    }

    @Test func aFullColumnTakesATabInItsLowerPane() {
        #expect(Rule.decide(.init(sourceWidth: 1400, panes: ["diff", "lower"])) == .tab("lower"))
    }

    @Test func aNarrowChatOrColumnNeverSplits() {
        #expect(Rule.decide(.init(sourceWidth: 959)) == .tab(nil), "half of 959 pt is under the chat's 480 pt")
        #expect(Rule.decide(.init(sourceWidth: 960)) == .splitRight)
        #expect(Rule.decide(.init(sourceWidth: 479, panes: ["diff"], widths: ["diff": 700])) == .tab("diff"))
        #expect(Rule.decide(.init(sourceWidth: 1400, panes: ["diff"], widths: ["diff": 419])) == .tab("diff"))
    }

    /// The column is read from frames, never from which pane was focused last (review of #28044 at
    /// 20e433f2: a recency-based neighbour walk read a two-pane column as one).
    @Test func theRightColumnIsEveryPaneAtTheSourcesRightEdgeTopToBottom() {
        let frames: [String: CGRect] = [
            "chat": CGRect(x: 0, y: 0, width: 700, height: 800),
            "lower": CGRect(x: 706, y: 404, width: 600, height: 396),
            "upper": CGRect(x: 706, y: 0, width: 600, height: 400),
            "far": CGRect(x: 1312, y: 0, width: 300, height: 800),
        ]
        #expect(Rule.column(beside: "chat", frames: frames) == ["upper", "lower"])
        #expect(Rule.column(beside: "upper", frames: frames) == ["far"])
        #expect(Rule.column(beside: "far", frames: frames).isEmpty)
        // A pane beside only the lower half of a half-height source is not in its column.
        let halves: [String: CGRect] = [
            "top": CGRect(x: 0, y: 0, width: 700, height: 400), "bottom": CGRect(x: 0, y: 404, width: 700, height: 396),
            "right-top": CGRect(x: 706, y: 0, width: 600, height: 400), "right-bottom": CGRect(x: 706, y: 404, width: 600, height: 396),
        ]
        #expect(Rule.column(beside: "top", frames: halves) == ["right-top"])
        // A column past a wide gap is not beside the source.
        #expect(Rule.column(beside: "chat", frames: ["chat": frames["chat"]!, "away": CGRect(x: 800, y: 0, width: 300, height: 800)]).isEmpty)
    }

    /// Leo 2026-10-31, of a link that split under the browser pane already on the right: "imo in this
    /// case, just open it on the existing. you only need the rightmost botom auto split when there's a
    /// terminal that gets opened when there's already a browser, and vice versa".
    @Test func aBrowserOrTerminalGoesToThePaneThatAlreadyHoldsItsKind() {
        let browser = Rule.Column(sourceWidth: 1400, panes: ["web"], widths: ["web": 700], kinds: ["web": [.browser]])
        #expect(Rule.decide(browser, opening: .browser) == .tab("web"), "a link with a browser on the right: a tab there")
        #expect(Rule.decide(browser, opening: .terminal) == .splitBelow("web"), "a terminal with a browser on the right: the split")
        let terminal = Rule.Column(sourceWidth: 1400, panes: ["shell"], widths: ["shell": 700], kinds: ["shell": [.terminal]])
        #expect(Rule.decide(terminal, opening: .terminal) == .tab("shell"))
        #expect(Rule.decide(terminal, opening: .browser) == .splitBelow("shell"))
        // Both kinds already split: each goes to its own pane, not only the lower one.
        let both = Rule.Column(sourceWidth: 1400, panes: ["web", "shell"], kinds: ["web": [.browser], "shell": [.terminal]])
        #expect(Rule.decide(both, opening: .browser) == .tab("web"))
        #expect(Rule.decide(both, opening: .terminal) == .tab("shell"))
        // A narrow column still takes the tab where its kind is; nothing on the right still splits right.
        #expect(Rule.decide(.init(sourceWidth: 479, panes: ["web"], kinds: ["web": [.browser]]), opening: .browser) == .tab("web"))
        #expect(Rule.decide(.init(sourceWidth: 1400), opening: .browser) == .splitRight)
        // No kind (a chat, a subagent, a file page): the rule as before.
        #expect(Rule.decide(browser) == .splitBelow("web"))
    }

    @MainActor @Test func closingTheLowerPaneCollapsesTheSplitAndTheNextOpenSplitsAgain() {
        let window = RightColumnWindow()
        window.occupy("diff")
        let lower = window.place(Rule.decide(window.measured), key: "one")
        #expect(window.live == ["right1", lower])
        window.close("one")
        #expect(window.live == ["right1"], "the lower pane went with its last tab")
        window.place(Rule.decide(window.measured), key: "two")
        #expect(window.events == ["split below right1", "split below right1"])
    }
}
