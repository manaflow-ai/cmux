import CmuxMobileAgentChat
@testable import CmuxMobileFeed
import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileLive

/// manaflow-ai/cmux#51332: the iPhone Feed filled with the Chief's memory compactor ("Claude-sr2 ·
/// slot-1", a raw "<chat> 0+2048|user: …" prompt, "Compacted 10648–10651: …"). The Feed is the
/// person's work: internal sessions never make a card, and each card names its chat, says what
/// happened in one line and carries its pull request's state.
@MainActor
@Suite struct FeedThreadsQualityTests {
    static func session(_ fields: String, harness: String = "claude-sr2") throws -> AcpmuxSession {
        let line = #"{"sessionId":"s1","harness":""# + harness + #"","cwd":"/tmp/w","status":"ready","pendingPermissions":0,"lastSeq":3,"lastTurn":{"status":"completed","turnId":"t1"},"#
            + fields + "}"
        return try #require(AcpmuxSession(try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))))
    }

    static func feed() -> (FeedStore, LiveFeed) {
        let store = FeedStore(items: [])
        return (store, LiveFeed(store: store, hub: nil, place: { _ in nil }))
    }

    // MARK: Internal sessions

    @Test func theChiefsCompactorNeverMakesACard() throws {
        let compactors = [
            try Self.session(#""name":"","tags":{"cmux.chief":"b902","cmux.chief.role":"compactor"},"preview":"Compacted 1–2: x""#),
            try Self.session(#""name":"optchat-compact-b902-slot-1","preview":"ok""#),
            // Untagged and unnamed: its folder is the slot's (`$TMPDIR/optchat-compact-<id>/slot-<k>`).
            try Self.session(#""name":"","cwd":"/var/folders/x/T/optchat-compact-b902/slot-1","preview":"ok""#),
        ]
        for session in compactors {
            #expect(session.isChiefCompactor)
            let (store, feed) = Self.feed()
            feed.handle(.sessionChanged(session, recordKind: "turn_result", seq: 4), sessions: [session.id: session])
            feed.hydrate([session])
            #expect(store.items.isEmpty, "\(session.name) \(session.cwd)")
        }
    }

    @Test func theChiefsOwnTurnsStayInTheChiefTab() throws {
        let turn = try Self.session(#""name":"optchat-b902d10e-816","preview":"Done.""#)
        #expect(turn.isChiefTurn)
        let (store, feed) = Self.feed()
        feed.hydrate([turn])
        #expect(store.items.isEmpty)
        // A Chief subagent's work is the person's: it stays.
        let sub = try Self.session(#""name":"optchat-sub-b902d10e-a12","preview":"Opened the PR.""#)
        #expect(!sub.isChiefTurn && !sub.isChiefCompactor)
        feed.hydrate([sub])
        #expect(store.items.count == 1)
    }

    @Test func cardsAnOlderBuildMadeForTheChiefLeave() throws {
        let compactor = try Self.session(#""name":"optchat-compact-b902-slot-0","preview":"ok""#)
        let stale = FeedItem(id: "turn-s1-t1", kind: .response, workspaceID: "", tabID: "s1", agentName: "Claude", harness: "claude-sr2",
                             workspaceTitle: "w", markdown: "ok", quote: nil, createdAt: Date())
        let store = FeedStore(items: [stale])
        let feed = LiveFeed(store: store, hub: nil, place: { _ in nil })
        #expect(store.items.count == 1)
        feed.hydrate([compactor])
        #expect(store.items.isEmpty)
    }

    @Test func aSavedCompactorCardIsDroppedWithoutItsSession() {
        let slot = FeedItem(id: "turn-x-1", kind: .response, workspaceID: "", tabID: "x", agentName: "Claude-sr2", harness: "claude-sr2",
                            workspaceTitle: "slot-1", markdown: "Compacted 10648–10651: the person asked…",
                            quote: .init("<chat> 0+2048|user: codex --yolo"), createdAt: Date())
        let work = FeedItem(id: "turn-y-1", kind: .response, workspaceID: "w1", tabID: "y", agentName: "Claude", harness: "claude",
                            workspaceTitle: "cmux", markdown: "Fixed it.", quote: nil, createdAt: Date())
        #expect(FeedInternal.isCompactorCard(slot))
        #expect(!FeedInternal.isCompactorCard(work))
        let store = FeedStore(items: [slot, work])
        #expect(store.items.map(\.id) == ["turn-y-1"])
        store.replaceAll([slot, work])
        #expect(store.items.map(\.id) == ["turn-y-1"])
    }

    @Test func aChiefViewPromptQuotesOnlyTheTask() throws {
        #expect(FeedInternal.shownPrompt("<chat>\n0+128|user: hi\n</chat>Your task:\n\nFix the feed.") == "Fix the feed.")
        #expect(FeedInternal.shownPrompt("<chat> 0+2048|user: codex --yolo") == nil)
        #expect(FeedInternal.shownPrompt("<chat>\n0+1|user: hi\n</chat>") == nil)
        #expect(FeedInternal.shownPrompt("plain prompt") == "plain prompt")
        let sub = try Self.session(#""name":"optchat-sub-b902-a3","lastPrompt":"<chat>\n0+9|user: x\n</chat>Your task:\nShip it.","preview":"Shipped.""#)
        let (_, feed) = Self.feed()
        #expect(feed.turnItem(sub, fallbackKey: "t1", at: Date()).quote?.text == "Ship it.")
    }

    // MARK: Cards

    @Test func aCardNamesTheAgentNotItsProfile() throws {
        let (_, feed) = Self.feed()
        let item = feed.turnItem(try Self.session(#""name":"fix-login","preview":"Done.""#), fallbackKey: "t1", at: Date())
        #expect(item.agentName == "Claude")
        #expect(HarnessName.display("claude-sr2") == "Claude")
        #expect(HarnessName.display("codex") == "Codex")
        #if os(iOS)
        #expect(FeedRowCell.avatarSymbol("claude-sr2") == FeedRowCell.avatarSymbol("claude"))
        #endif
    }

    @Test func aTurnCardCarriesItsPullRequestAndDevBuild() throws {
        let session = try Self.session(#""name":"fix-login","pullRequests":["https://github.com/manaflow-ai/cmux/pull/51400"],"preview":"Opened the PR. Dev build: tag `feed-threads`.""#)
        let (_, feed) = Self.feed()
        let item = feed.turnItem(session, fallbackKey: "t1", at: Date())
        #expect(item.pullRequest?.number == 51400)
        #expect(item.devBuild == "feed-threads")
        #expect(item.headline == "PR #51400 open")
        #expect(ChatActivity.devBuildTag(in: "Dev build `feed-threads` is up.") == "feed-threads")
    }

    @Test func aChiefHarnessTurnStaysOut() throws {
        let chief = try Self.session(#""name":"home","preview":"Done.""#, harness: "chief")
        #expect(!LiveFeed.showsTurns(of: chief))
    }

    @Test func thePrStateAnswerReadsAsChecksAndMergeability() throws {
        let url = try #require(URL(string: "https://github.com/manaflow-ai/cmux/pull/7"))
        func read(_ json: String) throws -> PullRequestSummary? {
            LiveFeed.pullSummary(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)), url: url)
        }
        let green = try #require(try read(#"{"pr":7,"state":"open","mergeable":"mergeable","failingChecks":[],"pendingChecks":0,"passedChecks":5,"title":"T"}"#))
        #expect(green.checks == .passing && green.mergeable == true && green.canMerge && green.stateText == "Ready to merge")
        let red = try #require(try read(#"{"pr":7,"state":"open","mergeable":"conflicts","failingChecks":["kit"],"pendingChecks":1,"passedChecks":5}"#))
        #expect(red.checks == .failing && !red.canMerge && red.stateText == "Checks failing")
        let merged = try #require(try read(#"{"pr":7,"state":"merged","mergeable":"mergeability unknown","failingChecks":[],"pendingChecks":0,"passedChecks":0}"#))
        #expect(merged.isMerged && !merged.canMerge && merged.stateText == "Merged")
        let draft = try #require(try read(#"{"pr":7,"state":"open","draft":true,"failingChecks":[],"pendingChecks":2,"passedChecks":0}"#))
        #expect(draft.state == .draft && draft.checks == .pending && !draft.canMerge)
        #expect(try read(#"{"state":"open"}"#) == nil)
    }

    @Test func theHeadlineSaysWhatHappenedAndTheDecision() throws {
        var item = FeedItem(id: "a", kind: .response, workspaceID: "w", tabID: "t", agentName: "Claude", harness: "claude",
                            workspaceTitle: "cmux", markdown: "x", quote: nil, createdAt: Date())
        #expect(item.headline == "Finished")
        #expect(item.decision == nil)
        let url = try #require(URL(string: "https://github.com/o/r/pull/9"))
        item.pullRequest = PullRequestSummary(url: url, number: 9, state: .open, checks: .passing, mergeable: true)
        #expect(item.headline == "PR #9 open")
        #expect(item.decision == .merge(item.pullRequest!))
        item.pullRequest?.checks = .failing
        #expect(item.decision == nil)
        item.pullRequest?.state = .merged
        #expect(item.headline == "Merged PR #9")
        item.pullRequest?.state = .open
        item.pullRequest?.checks = .passing
        item.kind = .failed
        #expect(item.headline == "Failed")
        // A failed turn's pull request is not offered for merging.
        #expect(item.decision == nil)
        item.tabTitle = "Fix login"
        #expect(item.title == "cmux › Fix login")
        #if os(iOS)
        let merge = FeedListController.mergePrompt(PullRequestSummary(url: url, number: 9))
        #expect(merge.contains(url.absoluteString))
        #endif
    }

    // MARK: Grouping

    @Test func eventsGroupByWorkspaceAfterTheOpenAsks() {
        func item(_ id: String, _ workspace: String, ago: TimeInterval, kind: FeedItem.Kind = .response) -> FeedItem {
            FeedItem(id: id, kind: kind, workspaceID: workspace, tabID: "t", agentName: "Claude", harness: "claude",
                     workspaceTitle: workspace, markdown: "x", quote: nil, createdAt: Date(timeIntervalSince1970: 10_000 - ago))
        }
        let ask = item("ask", "b", ago: 50, kind: .needsInput)
        let store = FeedStore(items: [item("a1", "a", ago: 0), item("b1", "b", ago: 10), item("a2", "a", ago: 20), ask, item("b2", "b", ago: 30)])
        #expect(store.visibleItems.map(\.id) == ["ask", "a1", "a2", "b1", "b2"])
        #expect(FeedThread.positions(store.visibleItems.map(\.threadKey)) == [.single, .first, .last, .first, .last])
    }
}
