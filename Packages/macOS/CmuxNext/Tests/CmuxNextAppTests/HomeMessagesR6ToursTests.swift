#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextHome
import CmuxNextSettings
import Testing

/// Review round 6 of cmux#37736 (F5): the DEBUG verbs the tours and the Home scripts call
/// (`debug.home.sidebar_fixture`, `debug.home.drive`, `debug.home`'s Messages list and transcript)
/// answer on a Home that is the Messages page, through its `home.messages.debug` op.
@MainActor @Suite
struct HomeMessagesR6ToursTests {
    /// What the page was asked, and a page that answers with `answer`.
    @MainActor final class Page {
        var asked: [(op: String, params: [String: JSONValue], within: Duration)] = []
        var hovered: [String] = []
        var answer: JSONValue? = .object(["ok": .bool(true)])

        var debug: HomeMessagesDebug {
            HomeMessagesDebug(ask: { [self] op, params, within in
                asked.append((op, params, within))
                return answer
            }, hover: { [self] selector in
                hovered.append(selector)
                return .object(["hovered": .bool(true)])
            })
        }
    }

    @Test func sidebarFixtureGoesToThePageAndHoverDraftMovesThePointer() async {
        let page = Page()
        _ = await page.debug.sidebarFixture(["count": .number(5), "pinned": .number(3)])
        #expect(page.asked.first?.op == "home.messages.debug")
        #expect(page.asked.first?.params["action"] == .string("fixture"))
        #expect(page.asked.first?.params["count"] == .number(5))
        let hover = await page.debug.sidebarFixture(["hover_draft": .bool(true)])
        #expect(page.hovered == [HomeMessagesDebug.draftRowSelector])
        #expect(hover["hovered"] == .bool(true))
        #expect(page.asked.count == 1, "the hover never asks the page's fixture")
    }

    @Test func aPageThatNeverAnswersFailsTheStep() async {
        let page = Page()
        page.answer = nil
        let fixture = await page.debug.sidebarFixture(["new_message": .number(3)])
        #expect(fixture["error"] != nil, "tour.py fails a step whose answer has an error")
        let drive = await page.debug.drive(["action": .string("texts")])
        #expect(drive["error"] == .string("no Home conversation is shown"))
    }

    @Test func driveForwardsListOpsAndTranscriptActions() async {
        let page = Page()
        _ = await page.debug.drive(["action": .string("list"), "op": .string("pin"), "conversation": .string("c1")])
        #expect(page.asked.last?.params["action"] == .string("list"))
        #expect(page.asked.last?.params["op"] == .string("pin"))
        _ = await page.debug.drive(["action": .string("type"), "text": .string("hi"), "tab": .string("k1")])
        #expect(page.asked.last?.params["action"] == .string("drive"))
        #expect(page.asked.last?.params["drive"] == .string("type"))
        #expect(page.asked.last?.params["text"] == .string("hi"))
        #expect(page.asked.last?.params["tab"] == nil, "the tab picks the page; the page never reads it")
        #expect(page.asked.last?.within == HomeMessagesDebug.actionDeadline)
    }

    @Test func snapshotIsShortAndFillsTheNativeKeys() async {
        let page = Page()
        page.answer = .object(["list": .array([.object(["id": .string("c1")])]), "transcript_tail": .array([.string("hello")]),
                               "open_thread": .string("m1"), "note": .null, "cloud": .null])
        let read = await page.debug.snapshot()
        #expect(page.asked.last?.within == HomeMessagesDebug.snapshotDeadline)
        let report: JSONValue = .object([
            "dock": .object(["mode": .string("messages")]),
            "page": .object(["tabs": .array([.object(["key": .string("k1")]), .object(["key": .string("k2")])])]),
        ])
        let merged = HomeMessagesDebug.merging(report: report, dock: read, tabs: ["k1": read ?? [:]])
        #expect(merged["dock"]?["messages_list"] == .array([.object(["id": .string("c1")])]))
        #expect(merged["dock"]?["transcript_tail"] == .array([.string("hello")]))
        #expect(merged["dock"]?["open_thread"] == .string("m1"))
        #expect(merged["dock"]?["mode"] == .string("messages"))
        let tabs = merged["page"]?["tabs"]?.arrayValue ?? []
        #expect(tabs.first?["transcript_tail"] == .array([.string("hello")]))
        #expect(tabs.last?["transcript_tail"] == .array([]), "a tab whose page did not answer reads as empty, not missing")
        // No docked Home (classic): the report's dock stays null.
        let classic = HomeMessagesDebug.merging(report: .object(["dock": .null]), dock: read, tabs: [:])
        #expect(classic["dock"] == .null)
    }
}
#endif
