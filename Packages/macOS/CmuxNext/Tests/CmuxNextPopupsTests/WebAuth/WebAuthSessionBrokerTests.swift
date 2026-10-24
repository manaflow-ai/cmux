@testable import CmuxNextPopups
import Foundation
import Testing

/// Each sign-in the system hands cmux ends exactly once: completed with its
/// callback URL (its tab closes), cancelled when the person closes the tab,
/// or closed without an answer when the system cancels it.
@Suite struct WebAuthSessionBrokerTests {
    private let callbackURL = URL(string: "https://app.example.com/done?code=42")!
    private let opener = FakeWebAuthOpener()
    private let broker: WebAuthSessionBroker

    init() {
        broker = WebAuthSessionBroker(opener: opener)
    }

    @Test func theCallbackCompletesTheSessionOnceAndClosesItsTab() throws {
        let request = FakeWebAuthRequest()
        broker.begin(request)
        let surface = try #require(opener.surfaces[request.id])
        #expect(!broker.navigated(request.id, to: URL(string: "https://accounts.example.com/password")!), "a sign-in page is not the callback")
        #expect(request.completions == 0)
        #expect(broker.navigated(request.id, to: callbackURL), "the caller must not load the callback")
        #expect(request.completedURL == callbackURL)
        #expect(surface.closes == 1)
        #expect(!broker.navigated(request.id, to: callbackURL), "a session ends once")
        broker.surfaceClosed(request.id)
        broker.systemCancelled(request.id)
        #expect(request.completions == 1)
        #expect(request.cancels == 0)
        #expect(surface.closes == 1)
        #expect(broker.pending.isEmpty)
    }

    @Test func closingTheTabCancelsTheSessionOnce() throws {
        let request = FakeWebAuthRequest()
        broker.begin(request)
        broker.surfaceClosed(request.id)
        broker.surfaceClosed(request.id)
        #expect(request.cancels == 1)
        #expect(!broker.navigated(request.id, to: callbackURL), "a cancelled session takes no callback")
        #expect(request.completions == 0)
        #expect(broker.pending.isEmpty)
    }

    @Test func theSystemCancellingClosesTheTabAndAnswersNothing() throws {
        let request = FakeWebAuthRequest()
        broker.begin(request)
        let surface = try #require(opener.surfaces[request.id])
        broker.systemCancelled(request.id)
        #expect(surface.closes == 1)
        broker.surfaceClosed(request.id) // the tab reports its close back
        #expect(request.cancels == 0, "the requesting app already ended it")
        #expect(request.completions == 0)
        #expect(broker.pending.isEmpty)
    }

    @Test func aCancelThatArrivesBeforeItsBeginOpensNothing() {
        let request = FakeWebAuthRequest()
        broker.systemCancelled(request.id)
        broker.begin(request)
        #expect(opener.opened.isEmpty)
        #expect(request.cancels == 0)
        #expect(request.completions == 0)
        #expect(broker.pending.isEmpty)
    }

    @Test func aSecondBeginForTheSameRequestOpensNoSecondTab() {
        let request = FakeWebAuthRequest()
        broker.begin(request)
        broker.begin(request)
        #expect(opener.opened == [request.id])
    }

    @Test(arguments: ["https://accounts.example.com/signin", "http://localhost:8080/signin"])
    func aWebStartPageOpens(url: String) throws {
        let request = FakeWebAuthRequest(url: try #require(URL(string: url)))
        broker.begin(request)
        #expect(opener.opened == [request.id])
        #expect(request.cancels == 0)
        #expect(broker.pending[request.id] != nil)
    }

    @Test(arguments: ["myapp://signin", "file:///etc/passwd", "about:blank", "javascript:alert(1)"])
    func anyOtherStartPageIsCancelledWithoutATab(url: String) throws {
        let request = FakeWebAuthRequest(url: try #require(URL(string: url)))
        broker.begin(request)
        #expect(opener.opened.isEmpty)
        #expect(request.cancels == 1)
        #expect(broker.pending.isEmpty)
    }

    @Test func noTabCancelsTheSession() {
        opener.opens = false
        let request = FakeWebAuthRequest()
        broker.begin(request)
        #expect(opener.opened == [request.id])
        #expect(request.cancels == 1)
        #expect(broker.pending.isEmpty)
    }

    @Test func aTabThatClosesWhileItOpensLeavesNoSession() throws {
        opener.duringOpen = { request, broker in broker.surfaceClosed(request.id) }
        let request = FakeWebAuthRequest()
        broker.begin(request)
        #expect(request.cancels == 1)
        #expect(broker.pending.isEmpty, "the closed tab's session is not brought back")
        broker.systemCancelled(request.id)
        #expect(try #require(opener.surfaces[request.id]).closes == 0)
    }

    @Test func aTabThatReachesTheCallbackWhileItOpensCompletesOnce() throws {
        let callbackURL = callbackURL
        opener.duringOpen = { request, broker in _ = broker.navigated(request.id, to: callbackURL) }
        let request = FakeWebAuthRequest()
        broker.begin(request)
        #expect(request.completedURL == callbackURL)
        #expect(request.cancels == 0)
        #expect(broker.pending.isEmpty)
    }
}
