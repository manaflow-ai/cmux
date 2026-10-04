import Foundation
import Testing

@testable import CmuxBrowser

/// HTTP credentials a session gives in a URL (`http://user:password@host/`)
/// answer only that session's own challenges: never another session's on a
/// tab both drive, and not after the session left.
@Suite("Browser REPL HTTP credentials")
struct BrowserReplHTTPCredentialsTests {
    private let url = URL(string: "http://alice:s3cret@intranet.example:8080/admin")!

    @Test func theSupplyingSessionsOwnNavigationUsesThem() throws {
        var credentials = BrowserReplHTTPCredentials()
        credentials.remember(url, sessionID: "a")
        let credential = try #require(credentials.credential(host: "INTRANET.example", port: 8080, actingSession: "a", creator: nil))
        #expect(credential.user == "alice")
        #expect(credential.password == "s3cret")
        // WebKit must not keep them for the data store, where every other
        // tab and session of the profile would send them.
        #expect(credential.persistence == .none)
    }

    // Two sessions drive a user's tab; B's own request to the same server
    // must not sign in with A's password.
    @Test func anotherSessionsChallengeNeverGetsThem() {
        var credentials = BrowserReplHTTPCredentials()
        credentials.remember(url, sessionID: "a")
        #expect(credentials.credential(host: "intranet.example", port: 8080, actingSession: "b", creator: nil) == nil)
        #expect(credentials.credential(host: "intranet.example", port: 8080, actingSession: nil, creator: nil) == nil, "the page's own request in a user's tab")
    }

    // In a tab the session created every request is its own, also the
    // page's subresources after the navigation committed.
    @Test func theCreatorsTabUsesTheCreatorsCredentials() {
        var credentials = BrowserReplHTTPCredentials()
        credentials.remember(url, sessionID: "creator")
        #expect(credentials.credential(host: "intranet.example", port: 8080, actingSession: nil, creator: "creator")?.user == "alice")
    }

    @Test func theyEndWithTheSession() {
        var credentials = BrowserReplHTTPCredentials()
        credentials.remember(url, sessionID: "a")
        credentials.sessionLeft("a")
        #expect(credentials.credential(host: "intranet.example", port: 8080, actingSession: "a", creator: "a") == nil)
    }

    @Test func theyMatchOnlyTheirHostAndPort() {
        var credentials = BrowserReplHTTPCredentials()
        credentials.remember(URL(string: "https://bob:pw@site.example/")!, sessionID: "a")
        #expect(credentials.credential(host: "site.example", port: 443, actingSession: "a", creator: nil)?.user == "bob")
        #expect(credentials.credential(host: "site.example", port: 80, actingSession: "a", creator: nil) == nil)
        #expect(credentials.credential(host: "other.example", port: 443, actingSession: "a", creator: nil) == nil)
        // A URL without a user name gives none.
        credentials.remember(URL(string: "https://site2.example/")!, sessionID: "a")
        #expect(credentials.credential(host: "site2.example", port: 443, actingSession: "a", creator: nil) == nil)
    }
}
