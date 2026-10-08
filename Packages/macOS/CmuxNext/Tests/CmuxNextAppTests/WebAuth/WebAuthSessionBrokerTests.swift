import Foundation
import Testing
@testable import CmuxNextApp

/// Another app's sign-in (ASWebAuthenticationSession) served by cmux as the
/// default browser: it opens in a tab, ends with the callback URL exactly
/// once, and is cancelled when the person closes the tab.
@MainActor
@Suite struct WebAuthSessionBrokerTests {
    final class Request: WebAuthSessionRequest {
        let id = UUID()
        let url: URL
        let isEphemeral: Bool
        let callback: WebAuthCallback
        var completed: [URL] = []
        var cancelled = 0
        init(_ url: String, ephemeral: Bool = false, callback: WebAuthCallback) {
            self.url = URL(string: url)!
            isEphemeral = ephemeral
            self.callback = callback
        }
        func matches(_ url: URL) -> Bool { callback.matches(url) }
        func complete(with url: URL) { completed.append(url) }
        func cancel() { cancelled += 1 }
    }

    final class Surface: WebAuthSessionSurface {
        var closed = 0
        func close() { closed += 1 }
    }

    final class Opener: WebAuthSessionOpening {
        var opened: [(URL, Bool, WebAuthCallback)] = []
        var refuses = false
        let surface = Surface()
        func open(_ request: any WebAuthSessionRequest, broker: WebAuthSessionBroker) -> (any WebAuthSessionSurface)? {
            opened.append((request.url, request.isEphemeral, request.callback))
            return refuses ? nil : surface
        }
    }

    @Test func aCustomSchemeCallbackCompletesOnceAndClosesTheTab() {
        let opener = Opener()
        let broker = WebAuthSessionBroker(opener: opener)
        let request = Request("https://accounts.example.com/authorize?x=1", callback: .customScheme("myapp"))
        broker.begin(request)
        #expect(opener.opened.count == 1)
        #expect(broker.navigated(request.id, to: URL(string: "https://accounts.example.com/next")!) == false)
        #expect(broker.navigated(request.id, to: URL(string: "myapp://done?code=42")!) == true)
        #expect(request.completed == [URL(string: "myapp://done?code=42")!])
        #expect(opener.surface.closed == 1)
        // Later events and a close of the finished tab change nothing.
        #expect(broker.navigated(request.id, to: URL(string: "myapp://done?code=43")!) == false)
        broker.surfaceClosed(request.id)
        #expect(request.completed.count == 1)
        #expect(request.cancelled == 0)
    }

    @Test func anHTTPSCallbackMatchesItsHostAndPathOnly() {
        let opener = Opener()
        let broker = WebAuthSessionBroker(opener: opener)
        let request = Request("https://id.example.com/login", callback: .https(host: "app.example.com", path: "/cb"))
        broker.begin(request)
        #expect(broker.navigated(request.id, to: URL(string: "https://app.example.com/other")!) == false)
        #expect(broker.navigated(request.id, to: URL(string: "https://evil.com/cb")!) == false)
        #expect(broker.navigated(request.id, to: URL(string: "https://APP.example.com/cb/?code=1")!) == true)
        #expect(request.completed.count == 1)
    }

    @Test func closingTheTabCancelsTheSignIn() {
        let opener = Opener()
        let broker = WebAuthSessionBroker(opener: opener)
        let request = Request("https://id.example.com/login", callback: .customScheme("myapp"))
        broker.begin(request)
        broker.surfaceClosed(request.id)
        #expect(request.cancelled == 1)
        #expect(request.completed.isEmpty)
        #expect(broker.pending.isEmpty)
    }

    @Test func theSystemCancellingClosesTheTabWithoutAnAnswer() {
        let opener = Opener()
        let broker = WebAuthSessionBroker(opener: opener)
        let request = Request("https://id.example.com/login", callback: .customScheme("myapp"))
        broker.begin(request)
        broker.systemCancelled(request.id)
        #expect(opener.surface.closed == 1)
        #expect(request.cancelled == 0, "the system already ended it")
        broker.surfaceClosed(request.id)
        #expect(request.cancelled == 0)
    }

    @Test func aRequestThatCannotOpenIsCancelled() {
        let opener = Opener()
        opener.refuses = true
        let broker = WebAuthSessionBroker(opener: opener)
        let request = Request("https://id.example.com/login", callback: .customScheme("myapp"))
        broker.begin(request)
        #expect(request.cancelled == 1)
        for text in ["file:///etc/hosts", "javascript:alert(1)", "myapp://start"] {
            let bad = Request(text, callback: .customScheme("myapp"))
            broker.begin(bad)
            #expect(bad.cancelled == 1, "\(text)")
        }
        #expect(opener.opened.count == 1, "only the https start page opened")
    }

    @Test func ephemeralSessionsAskForANonPersistentProfile() {
        let opener = Opener()
        let broker = WebAuthSessionBroker(opener: opener)
        broker.begin(Request("https://id.example.com/login", ephemeral: true, callback: .customScheme("myapp")))
        #expect(opener.opened.first?.1 == true)
    }

    @Test func callbackMatchingFollowsTheSystemRule() {
        let scheme = WebAuthCallback.customScheme("MyApp")
        #expect(scheme.matches(URL(string: "myapp://x")!))
        #expect(!scheme.matches(URL(string: "myapp2://x")!))
        let https = WebAuthCallback.https(host: "example.com", path: "/cb")
        #expect(https.matches(URL(string: "https://example.com/cb?code=1#f")!))
        #expect(https.matches(URL(string: "https://EXAMPLE.COM/cb/")!))
        #expect(!https.matches(URL(string: "http://example.com/cb")!))
        #expect(!https.matches(URL(string: "https://example.com/cb2")!))
        #expect(!https.matches(URL(string: "https://example.com.evil.com/cb")!))
        #expect(!WebAuthCallback.none.matches(URL(string: "myapp://x")!))
    }
}
