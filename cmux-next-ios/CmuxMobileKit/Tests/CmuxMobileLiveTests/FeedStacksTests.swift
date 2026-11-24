@testable import CmuxMobileFeed
import CmuxMobileAgentChat
import Foundation
import Testing

/// Stacks (`FeedStacks`): one chat's events in a row show as the newest event and a fold line
/// ("3 earlier updates"); a tap on the line shows the older ones in place.
@MainActor
@Suite struct FeedStacksTests {
    static func item(_ id: String, chat: String = "a", workspace: String = "w", kind: FeedItem.Kind = .response) -> FeedItem {
        FeedItem(id: id, kind: kind, workspaceID: workspace, tabID: chat, agentName: "Claude", harness: "claude",
                 workspaceTitle: "cmux", markdown: "body \(id)", quote: nil, createdAt: Date(timeIntervalSince1970: 1_000_000))
    }

    static var permission: FeedItem.Kind {
        .permission(ACPPermissionRequest(
            id: "p", toolCall: ACPToolCall(id: "x", title: "deploy", kind: .execute),
            options: [ACPPermissionOption(id: "allow", name: "Allow once", kind: .allowOnce)]
        ))
    }

    static func stacks(_ items: [FeedItem], expanded: Set<String> = [], open: Set<String> = []) -> (FeedStacks, Set<String>) {
        var expanded = expanded
        let stacks = FeedStacks(items, expanded: &expanded, open: open)
        return (stacks, expanded)
    }

    @Test func aRunFromOneChatFoldsUnderItsNewestEvent() {
        let items = [Self.item("b1", chat: "b"), Self.item("a4"), Self.item("a3"), Self.item("a2"), Self.item("a1"), Self.item("b0", chat: "b")]
        let (stacks, _) = Self.stacks(items)
        let fold = FeedStacks.foldID(head: "a4")
        #expect(stacks.rows.map(\.id) == ["b1", "a4", fold, "b0"])
        #expect(stacks.folds == [fold: FeedFold(count: 3, expanded: false)])
        #expect(stacks.heads == ["a4"])
        #expect(stacks.hidden == ["a3", "a2", "a1"])
        #expect(stacks.folds[fold]?.title == "3 earlier updates")
        #expect(FeedStacks.head(ofFold: fold) == "a4")
        #expect(FeedStacks.isFold(fold) && !FeedStacks.isFold("a4"))
    }

    @Test func anotherChatsEventBetweenThemEndsTheRun() {
        let items = [Self.item("a3"), Self.item("b1", chat: "b"), Self.item("a2"), Self.item("a1")]
        let (stacks, _) = Self.stacks(items)
        #expect(stacks.rows.map(\.id) == ["a3", "b1", "a2", FeedStacks.foldID(head: "a2")])
        #expect(stacks.folds[FeedStacks.foldID(head: "a2")]?.title == "1 earlier update")
    }

    @Test func theSameTabInAnotherWorkspaceOrOnAnotherMacIsAnotherChat() {
        var other = Self.item("a1")
        other.macID = "mac-2"
        let items = [Self.item("a3"), Self.item("a2", workspace: "w2"), other]
        let (stacks, _) = Self.stacks(items)
        #expect(stacks.rows.map(\.id) == ["a3", "a2", "a1"])
        #expect(stacks.folds.isEmpty && stacks.heads.isEmpty)
    }

    @Test func anOpenStackShowsItsOlderEventsUnderTheFoldLine() {
        let items = [Self.item("a3"), Self.item("a2"), Self.item("a1"), Self.item("b1", chat: "b")]
        let (stacks, expanded) = Self.stacks(items, expanded: ["a3"])
        let fold = FeedStacks.foldID(head: "a3")
        #expect(stacks.rows.map(\.id) == ["a3", fold, "a2", "a1", "b1"])
        #expect(stacks.folds[fold] == FeedFold(count: 2, expanded: true))
        #expect(stacks.hidden.isEmpty)
        #expect(expanded == ["a3"])
    }

    @Test func aRowThatNeedsYouIsNeverFoldedAndLeadsNoStack() {
        let ask = Self.item("ask", kind: Self.permission)
        #expect(ask.needsYou)
        let (stacks, _) = Self.stacks([Self.item("a4"), Self.item("a3"), ask, Self.item("a2"), Self.item("a1")])
        #expect(stacks.rows.map(\.id) == ["a4", FeedStacks.foldID(head: "a4"), "ask", "a2", FeedStacks.foldID(head: "a2")])
        // An ask first (the Feed pins them): the chat's later events are not folded under it.
        let (pinned, _) = Self.stacks([ask, Self.item("a2"), Self.item("a1")])
        #expect(pinned.rows.map(\.id) == ["ask", "a2", FeedStacks.foldID(head: "a2")])
        // An answer on its way or a refused answer stays in sight too.
        var refused = Self.item("a2")
        refused.error = "The Mac refused it."
        var sending = Self.item("a1")
        sending.pending = "Sending…"
        let (kept, _) = Self.stacks([Self.item("a3"), refused, sending])
        #expect(kept.rows.map(\.id) == ["a3", "a2", "a1"])
    }

    @Test func aRowWithAnOpenReplyIsNeverFoldedButMayLeadAStack() {
        let items = [Self.item("a3"), Self.item("a2"), Self.item("a1")]
        let (older, _) = Self.stacks(items, open: ["a2"])
        #expect(older.rows.map(\.id) == ["a3", "a2", FeedStacks.foldID(head: "a2")])
        let (head, _) = Self.stacks(items, open: ["a3"])
        #expect(head.rows.map(\.id) == ["a3", FeedStacks.foldID(head: "a3")])
    }

    @Test func anOpenStackStaysOpenWhenItsChatPostsAgain() {
        let (stacks, expanded) = Self.stacks([Self.item("a4"), Self.item("a3"), Self.item("a2"), Self.item("a1")], expanded: ["a3"])
        #expect(expanded == ["a4"])
        #expect(stacks.rows.map(\.id) == ["a4", FeedStacks.foldID(head: "a4"), "a3", "a2", "a1"])
    }

    @Test func aStackThatIsGoneForgetsItWasOpen() {
        // Its newest event was marked done: the next one leads a new, folded stack.
        let (stacks, expanded) = Self.stacks([Self.item("b1", chat: "b"), Self.item("a2"), Self.item("a1")], expanded: ["a3", "gone"])
        #expect(expanded.isEmpty)
        #expect(stacks.rows.map(\.id) == ["b1", "a2", FeedStacks.foldID(head: "a2")])
    }

    @Test func foldLinesHaveTheirOwnLayoutKey() {
        // The fold row's event changes when its chat does, and its count and open state are its row state.
        let (stacks, _) = Self.stacks([Self.item("a2"), Self.item("a1")])
        let fold = stacks.rows[1]
        #expect(fold.id == FeedStacks.foldID(head: "a2") && fold.markdown.isEmpty && fold.agentName == "Claude")
        #expect(FeedRowState(fold: stacks.folds[fold.id]) != FeedRowState())
    }

    @Test func mockContentHasAStackOfFour() {
        let (stacks, _) = Self.stacks(FeedStore.pinningNeedsYou(FeedStore.mockItems(now: Date())))
        #expect(stacks.folds == [FeedStacks.foldID(head: "f-run-4"): FeedFold(count: 3, expanded: false)])
    }
}
