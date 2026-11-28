import Testing

@testable import CmuxBrowser

/// A dialog or file chooser routed to one session of a shared tab is that
/// session's to answer.
@Suite("Browser REPL routed requests")
struct BrowserReplRoutedRequestsTests {
    @Test func onlyTheOwningSessionAnswers() {
        var requests = BrowserReplRoutedRequests<String>()
        requests.add(id: "d1", owner: "owner", respond: "answer")
        #expect(requests.take(id: "d1", sessionID: "other") == nil)
        #expect(!requests.isEmpty, "a refused answer leaves the request open")
        #expect(requests.take(id: "d1", sessionID: "owner") == "answer")
        #expect(requests.take(id: "d1", sessionID: "owner") == nil, "answered once")
        #expect(requests.isEmpty)
    }

    @Test func aLeavingSessionGivesBackOnlyItsOwnRequests() {
        var requests = BrowserReplRoutedRequests<String>()
        requests.add(id: "d1", owner: "a", respond: "a1")
        requests.add(id: "d2", owner: "b", respond: "b1")
        requests.add(id: "d3", owner: "a", respond: "a2")
        #expect(requests.removeAll(ownedBy: "a").sorted() == ["a1", "a2"])
        #expect(requests.take(id: "d2", sessionID: "b") == "b1")
        #expect(requests.isEmpty)
    }

    @Test func removingEverythingReturnsEveryResponder() {
        var requests = BrowserReplRoutedRequests<Int>()
        requests.add(id: "c1", owner: "a", respond: 1)
        requests.add(id: "c2", owner: "b", respond: 2)
        #expect(requests.removeAll().sorted() == [1, 2])
        #expect(requests.isEmpty)
    }
}
