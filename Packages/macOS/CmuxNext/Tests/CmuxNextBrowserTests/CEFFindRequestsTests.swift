@testable import CmuxNextBrowser
import Testing

/// Find in a hosted Chromium page (plans/cmux-next/chrome-parity/p01-process.md):
/// FIND_RESULT carries the caller's find id, so a result already on the wire for an older search
/// never answers the newer one, and every result of the current search drives the find pill.
@MainActor @Suite struct CEFFindRequestsTests {
    /// What one request saw: its answers (exactly one when it ends) and its updates.
    final class Seen {
        var answers: [BrowserFindResult] = []
        var updates: [BrowserFindResult] = []
    }

    private func begin(_ requests: inout CEFFindRequests, _ seen: Seen) -> Int32 {
        requests.begin(answer: { seen.answers.append($0) }, update: { seen.updates.append($0) })
    }

    @Test func theEventCarriesTheCallersFindID() {
        let event = CEFShimEvent(kind: 14, browser: 7, request: 41, a: 3, b: 2 | (1 << 32), s1: "", s2: "")
        guard case .findResult(let browser, let findID, let count, let active, let isFinal) = event else {
            Issue.record("kind 14 is not a find result: \(event)")
            return
        }
        #expect(browser == 7 && findID == 41 && count == 3 && active == 2 && isFinal)
        guard case .findResult(_, _, _, _, let interim) = CEFShimEvent(kind: 14, browser: 7, request: 41, a: 3, b: 2, s1: "", s2: "") else {
            Issue.record("kind 14 is not a find result")
            return
        }
        #expect(!interim, "bit 32 of b is the final flag")
    }

    /// The host-mode race: the person typed "a" then "ab"; the final result of "a" was on the wire
    /// when "ab" left cmux. It must not answer "ab" (its count is the wrong word's).
    @Test func aResultOfAnOlderSearchNeverAnswersTheNewerOne() {
        var requests = CEFFindRequests()
        let first = Seen(), second = Seen()
        let a = begin(&requests, first)
        let ab = begin(&requests, second)
        #expect(a != ab)
        #expect(first.answers == [.none], "the newer search answers the older request with none")

        let dropped = requests.result(findID: a, count: 9, active: 1, isFinal: true)
        #expect(dropped?.result == nil)
        #expect(second.answers.isEmpty, "the older search's final result does not answer the newer request")
        #expect(second.updates.isEmpty && first.updates.isEmpty, "nor does it reach the pill")

        requests.result(findID: ab, count: 2, active: 1, isFinal: true)?.run()
        #expect(second.answers == [BrowserFindResult(matchFound: true, matchCount: 2, currentIndex: 1)])
        #expect(second.updates == second.answers)
    }

    /// Chrome's find bar shows the count while Chromium still searches the page; "No matches"
    /// shows only once the search ended with none.
    @Test func everyResultOfTheCurrentSearchDrivesThePill() {
        var requests = CEFFindRequests()
        let seen = Seen()
        let id = begin(&requests, seen)

        let dropped = requests.result(findID: id, count: 0, active: 0, isFinal: false)
        #expect(dropped?.result == nil, "no match yet: nothing to show")
        requests.result(findID: id, count: 4, active: 1, isFinal: false)?.run()
        #expect(seen.answers.isEmpty, "an interim count does not answer the request")
        #expect(seen.updates == [BrowserFindResult(matchFound: true, matchCount: 4, currentIndex: 1)])

        requests.result(findID: id, count: 7, active: 1, isFinal: true)?.run()
        #expect(seen.answers == [BrowserFindResult(matchFound: true, matchCount: 7, currentIndex: 1)])
        #expect(seen.updates.last == seen.answers.last)
    }

    /// A Find Next sent while the previous step's results were still coming: Chromium's reply to the
    /// previous step may carry the new id and answer it; the step's own final result then corrects
    /// the pill.
    @Test func aLaterResultOfTheSameSearchCorrectsThePill() {
        var requests = CEFFindRequests()
        let seen = Seen()
        let id = begin(&requests, seen)
        requests.result(findID: id, count: 5, active: 2, isFinal: true)?.run()
        requests.result(findID: id, count: 5, active: 3, isFinal: true)?.run()
        #expect(seen.answers.count == 1, "the request is answered once")
        #expect(seen.updates.map(\.currentIndex) == [2, 3], "the pill shows the step's own result last")
    }

    @Test func aSearchWithNoMatchAnswersNoMatchAndShowsIt() {
        var requests = CEFFindRequests()
        let seen = Seen()
        let id = begin(&requests, seen)
        requests.result(findID: id, count: 0, active: 0, isFinal: true)?.run()
        #expect(seen.answers == [BrowserFindResult(matchFound: false, matchCount: 0, currentIndex: nil)])
        #expect(seen.updates == seen.answers)
    }

    @Test func clearFindAnswersThePendingRequestAndDropsLaterResults() {
        var requests = CEFFindRequests()
        let seen = Seen()
        let id = begin(&requests, seen)
        requests.cancel()
        #expect(seen.answers == [.none])
        #expect(requests.currentID == 0)
        let dropped = requests.result(findID: id, count: 3, active: 1, isFinal: true)
        #expect(dropped?.result == nil, "Clear Find ended the search")
        #expect(seen.answers.count == 1 && seen.updates.isEmpty)
    }

    @Test func aResultWithNoFindIDAnswersNothing() {
        var requests = CEFFindRequests()
        let seen = Seen()
        _ = begin(&requests, seen)
        let dropped = requests.result(findID: 0, count: 3, active: 1, isFinal: true)
        #expect(dropped?.result == nil)
        #expect(seen.answers.isEmpty)
    }

    @Test func findIDsAreNeverZeroAndNeverRepeatBackToBack() {
        var requests = CEFFindRequests()
        let seen = Seen()
        var last: Int32 = 0
        for _ in 0..<5 {
            let id = begin(&requests, seen)
            #expect(id != 0 && id != last)
            last = id
        }
    }
}
