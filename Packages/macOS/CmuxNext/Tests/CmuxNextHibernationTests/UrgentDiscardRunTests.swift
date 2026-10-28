import CmuxNextHibernation
import Testing

/// ``UrgentDiscardRanker/run(_:)``: the critical memory event's one pass over every
/// owner's hidden pages (browser tabs, agent chats, cmux pages) discards exactly one page, the first
/// of the joint ranking its owner can discard, through that owner only; then every owner hears that the
/// pass ran.
@Suite struct UrgentDiscardRunTests {
    typealias Candidate = UrgentDiscardRanker.Candidate

    /// An owner that offers fixed candidates and records what the pass asks of it.
    final class Owner: UrgentDiscardOwner {
        let candidates: [Candidate]
        var refuses: Set<String> = []
        var discarded: [String] = []
        var passesHeard = 0

        init(_ candidates: [Candidate]) {
            self.candidates = candidates
        }

        func urgentCandidates() -> [Candidate] { candidates }

        func urgentDiscard(_ key: String) -> Bool {
            guard !refuses.contains(key) else { return false }
            discarded.append(key)
            return true
        }

        func urgentPassDidRun() { passesHeard += 1 }
    }

    let ranker = UrgentDiscardRanker()

    @Test(arguments: [("tab-old", ContentKind.browser), ("chat-old", .agentPage), ("page-old", .internalPage)])
    func oneCriticalEventDiscardsOnlyTheLongestHiddenOfEveryKindThroughItsOwner(_ oldest: String, _ kind: ContentKind) {
        func hidden(_ key: String, _ base: Double) -> Double { key == oldest ? 5_000 : base }
        let tabs = Owner([Candidate(key: "tab-old", kind: .browser, hiddenFor: hidden("tab-old", 900)),
                          Candidate(key: "tab-new", kind: .browser, hiddenFor: 700)])
        let chats = Owner([Candidate(key: "chat-old", kind: .agentPage, hiddenFor: hidden("chat-old", 1_000))])
        let pages = Owner([Candidate(key: "page-old", kind: .internalPage, hiddenFor: hidden("page-old", 800))])

        let pass = ranker.run([tabs, chats, pages])

        #expect(pass.keys == [oldest], "one critical event discarded \(pass.keys)")
        #expect(pass.discards.first?.kind == kind)
        #expect((tabs.discarded + chats.discarded + pages.discarded) == [oldest], "another owner discarded too")
        for owner in [tabs, chats, pages] { #expect(owner.passesHeard == 1, "an owner never heard the pass ran") }
    }

    /// Chrome's urgent pass takes protected pages last: a page hidden less than 10 minutes waits behind
    /// an older one of another kind.
    @Test func aRecentlyHiddenPageOfAnyKindGoesAfterAnOlderOne() {
        let tabs = Owner([Candidate(key: "tab", kind: .browser, hiddenFor: 120)])
        let chats = Owner([Candidate(key: "chat", kind: .agentPage, hiddenFor: 700)])
        #expect(ranker.run([tabs, chats]).keys == ["chat"])
        #expect(tabs.discarded.isEmpty)
    }

    /// A page its owner cannot discard now (shown since, or its discard would free nothing) passes the
    /// turn to the next one: the event still discards one page.
    @Test func aRefusedPageHandsTheTurnToTheNextOne() {
        let pages = Owner([Candidate(key: "page", kind: .internalPage, hiddenFor: 3_000)])
        pages.refuses = ["page"]
        let tabs = Owner([Candidate(key: "tab", kind: .browser, hiddenFor: 900)])
        let pass = ranker.run([pages, tabs])
        #expect(pass.keys == ["tab"])
        #expect(pass.refused == ["page"])
        #expect(tabs.discarded == ["tab"])
    }

    @Test func withNothingToDiscardEveryOwnerStillHearsThePass() {
        let tabs = Owner([]), chats = Owner([])
        let pass = ranker.run([tabs, chats])
        #expect(pass.discards.isEmpty)
        #expect(tabs.passesHeard == 1 && chats.passesHeard == 1)
    }

    /// A key two owners list is the first owner's: only it is asked to discard it.
    @Test func aKeyTwoOwnersListBelongsToTheFirst() {
        let first = Owner([Candidate(key: "k", kind: .browser, hiddenFor: 900)])
        let second = Owner([Candidate(key: "k", kind: .internalPage, hiddenFor: 2_000)])
        #expect(ranker.run([first, second]).keys == ["k"])
        #expect(first.discarded == ["k"])
        #expect(second.discarded.isEmpty)
    }
}
