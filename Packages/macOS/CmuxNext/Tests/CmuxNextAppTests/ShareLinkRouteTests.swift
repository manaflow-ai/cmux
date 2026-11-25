import CmuxNextDaemon
import CmuxNextOnboarding
import Foundation
import Testing

/// A chat share link handed to the app (a click on a share page, or the guest page's open-in-app
/// `<scheme>://share?link=...#<secret>`) routes to `.shareLink`, which asks the daemon for the page to
/// open in a guest browser tab; everything else keeps its route.
@Suite struct ShareLinkRouteTests {
    let router = ExternalOpenRouter(linkScheme: "cmux-dev")
    let share = "c2hhcmUtMDAwMDAwMDAwMDAx"

    func route(_ link: String) throws -> ExternalOpenRoute {
        router.route(try #require(URL(string: link)))
    }

    @Test func aSharePageOpensAsAShareLink() throws {
        for link in [
            "https://share.cmux.dev/g/\(share)#c2VjcmV0LTAwMDAwMDAwMDAx",
            "https://share-dev.cmux.dev/i/\(share)",
            "https://cmux-platform-production.debussy.workers.dev/g/\(share)/",
        ] {
            #expect(try route(link) == .shareLink(try #require(URL(string: link))), "\(link)")
        }
    }

    @Test func theGuestPagesAppLinkOpensAsAShareLink() throws {
        let link = "cmux-dev://share?link=https%3A%2F%2Fshare-dev.cmux.dev%2Fg%2F\(share)#c2VjcmV0LTAwMDAwMDAwMDAx"
        #expect(try route(link) == .shareLink(try #require(URL(string: link))))
        // Another build's scheme is not this build's link; other hosts of this scheme stay deep links.
        #expect(try route("cmux-nightly://share?link=x") == .unsupported)
        #expect(try route("cmux-dev://tab/1") == .deepLink(try #require(URL(string: "cmux-dev://tab/1"))))
        #expect(try route("cmux-dev://auth-callback?code=1") == .unsupported)
    }

    @Test func otherPagesStayBrowserTabs() throws {
        for link in [
            "https://example.com/g/short",
            "https://example.com/g/\(share)/more",
            "https://example.com/x/\(share)",
            "http://share.cmux.dev/g/\(share)",
            "https://share.cmux.dev/",
        ] {
            #expect(try route(link) == .browserTab(try #require(URL(string: link))), "\(link)")
        }
    }

    @Test func aWebLinkFromInsideCmuxKeepsItsShareRoute() throws {
        let url = try #require(URL(string: "https://share.cmux.dev/g/\(share)"))
        #expect(router.routeWebLink(url) == .shareLink(url))
    }

    @Test func aSharePageContinuedFromAnotherDeviceOpensAsAShareLink() throws {
        let page = try #require(URL(string: "https://share.cmux.dev/g/\(share)"))
        #expect(router.route(continuing: NSUserActivityTypeBrowsingWeb, webpageURL: page) == .shareLink(page))
        let other = try #require(URL(string: "https://example.com/docs"))
        #expect(router.route(continuing: NSUserActivityTypeBrowsingWeb, webpageURL: other) == .browserTab(other))
    }

    @Test func theDaemonRequestCarriesTheLinkAndTokenAndDecodesItsAnswer() throws {
        #expect(AgentSessionShareOpenLinkRequest.command == "agent-session-share-open-link")
        let answer = try JSONDecoder().decode(
            AgentSessionShareOpenedLink.self,
            from: Data(#"{"url":"https://share.cmux.dev/g/x?in_app=1#s","signed_in":true}"#.utf8))
        #expect(answer == AgentSessionShareOpenedLink(url: "https://share.cmux.dev/g/x?in_app=1#s", signedIn: true))
    }
}
