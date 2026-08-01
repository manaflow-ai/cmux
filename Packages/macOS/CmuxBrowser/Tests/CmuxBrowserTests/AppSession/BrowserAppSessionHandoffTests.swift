import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Browser app session handoff")
struct BrowserAppSessionHandoffTests {
    @Test("split-right app links stay on-origin and remove the routing marker")
    func resolvesSplitRightLink() throws {
        let origin = try #require(URL(string: "https://cmux.test"))
        let url = try #require(URL(
            string: "https://cmux.test/dashboard/testflight?plan=pro&cmux_open_in_browser=split-right#join"
        ))

        let request = try #require(BrowserAppLinkOpenRequest(
            url: url,
            webOrigin: origin
        ))

        #expect(
            request.destinationURL.absoluteString
                == "https://cmux.test/dashboard/testflight?plan=pro#join"
        )
    }

    @Test("split-right app links reject off-origin and unmarked destinations")
    func rejectsUnsafeSplitRightLinks() throws {
        let origin = try #require(URL(string: "https://cmux.test"))
        let offOrigin = try #require(URL(
            string: "https://example.test/dashboard/testflight?cmux_open_in_browser=split-right"
        ))
        let unmarked = try #require(URL(string: "https://cmux.test/dashboard/testflight"))

        #expect(BrowserAppLinkOpenRequest(url: offOrigin, webOrigin: origin) == nil)
        #expect(BrowserAppLinkOpenRequest(url: unmarked, webOrigin: origin) == nil)
    }

    @Test("handoff posts a coherent credential pair and preserves the destination path")
    func buildsHandoffRequest() throws {
        let origin = try #require(URL(string: "https://cmux.test"))
        let destination = try #require(URL(
            string: "https://cmux.test/dashboard/testflight?plan=pro#join"
        ))
        let handoff = BrowserAppSessionHandoff(webOrigin: origin)

        let request = try #require(handoff.request(
            destinationURL: destination,
            tokens: BrowserAppSessionTokens(
                accessToken: "native&access",
                refreshToken: "native&refresh"
            )
        ))
        let bodyData = try #require(request.httpBody)
        let body = try #require(String(data: bodyData, encoding: .utf8))

        #expect(request.url?.absoluteString == "https://cmux.test/handler/app-session-handoff")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-Cmux-App-Session-Handoff") == "1")
        #expect(request.value(forHTTPHeaderField: "X-Cmux-App-Session-Response") == "cookies")
        #expect(request.value(forHTTPHeaderField: "Referrer-Policy") == nil)
        #expect(body.contains("access_token=native%26access"))
        #expect(body.contains("refresh_token=native%26refresh"))
        #expect(body.contains("after=%2Fdashboard%2Ftestflight%3Fplan%3Dpro%23join"))
        #expect(request.url?.query == nil)
    }

    @Test("accepts only a complete cookie exchange response")
    func validatesCookieExchangeResponse() throws {
        let origin = try #require(URL(string: "https://cmux.test"))
        let handoff = BrowserAppSessionHandoff(webOrigin: origin)
        let response = try #require(HTTPURLResponse(
            url: origin.appendingPathComponent("handler/app-session-handoff"),
            statusCode: 204,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "X-Cmux-App-Session-Handoff": "ready",
                "Set-Cookie": "hexclave-access=access; Path=/; Secure; SameSite=Lax, __Host-hexclave-refresh-project-123--default=refresh; Path=/; Secure; SameSite=Lax",
            ]
        ))

        let cookies = try #require(handoff.sessionCookies(
            from: response,
            projectID: "project-123"
        ))
        #expect(cookies.map(\.name).sorted() == [
            "__Host-hexclave-refresh-project-123--default",
            "hexclave-access",
        ])

        let incomplete = try #require(HTTPURLResponse(
            url: origin,
            statusCode: 204,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "X-Cmux-App-Session-Handoff": "ready",
                "Set-Cookie": "hexclave-access=access; Path=/; Secure",
            ]
        ))
        #expect(handoff.sessionCookies(from: incomplete, projectID: "project-123") == nil)
    }

    @Test("accepts cookie exchange headers with HTTP/2 lowercase names")
    func acceptsLowercaseCookieExchangeHeaders() throws {
        let origin = try #require(URL(string: "https://cmux.test"))
        let handoff = BrowserAppSessionHandoff(webOrigin: origin)
        let response = try #require(LowercaseHeaderHTTPURLResponse(
            url: origin.appendingPathComponent("handler/app-session-handoff"),
            statusCode: 204,
            httpVersion: "HTTP/2",
            headerFields: [
                "X-Cmux-App-Session-Handoff": "ready",
                "Set-Cookie": "hexclave-access=access; Path=/; Secure; SameSite=Lax, __Host-hexclave-refresh-project-123--default=refresh; Path=/; Secure; SameSite=Lax",
            ]
        ))

        let cookies = try #require(handoff.sessionCookies(
            from: response,
            projectID: "project-123"
        ))
        #expect(cookies.map(\.name).sorted() == [
            "__Host-hexclave-refresh-project-123--default",
            "hexclave-access",
        ])
    }

    @Test("handoff rejects an empty refresh token")
    func rejectsEmptyRefreshToken() throws {
        let origin = try #require(URL(string: "https://cmux.test"))
        let destination = try #require(URL(string: "https://cmux.test/dashboard/testflight"))
        let handoff = BrowserAppSessionHandoff(webOrigin: origin)

        #expect(handoff.request(
            destinationURL: destination,
            tokens: BrowserAppSessionTokens(accessToken: "access", refreshToken: "")
        ) == nil)
    }

    @Test("handoff rejects off-origin and recursive destinations")
    func rejectsUnsafeHandoffDestinations() throws {
        let origin = try #require(URL(string: "https://cmux.test"))
        let handoff = BrowserAppSessionHandoff(webOrigin: origin)
        let tokens = BrowserAppSessionTokens(
            accessToken: "native-access",
            refreshToken: "native-refresh"
        )
        let offOrigin = try #require(URL(string: "https://example.test/dashboard"))
        let recursive = try #require(URL(
            string: "https://cmux.test/handler/app-session-handoff?after=/dashboard"
        ))

        #expect(handoff.request(destinationURL: offOrigin, tokens: tokens) == nil)
        #expect(handoff.request(destinationURL: recursive, tokens: tokens) == nil)
    }

    @Test("cookie deletion stays scoped to Stack cookies on the cmux origin")
    func scopesCookieDeletion() throws {
        let origin = try #require(URL(string: "https://cmux.test"))
        let handoff = BrowserAppSessionHandoff(webOrigin: origin)

        #expect(handoff.shouldDeleteCookie(
            name: "stack-access",
            domain: "cmux.test",
            projectID: "project-123"
        ))
        #expect(handoff.shouldDeleteCookie(
            name: "__Host-stack-refresh-project-123--default",
            domain: ".cmux.test",
            projectID: "project-123"
        ))
        #expect(handoff.shouldDeleteCookie(
            name: "__Host-hexclave-refresh-project-123--default",
            domain: ".cmux.test",
            projectID: "project-123"
        ))
        #expect(handoff.shouldDeleteCookie(
            name: "hexclave-access",
            domain: "cmux.test",
            projectID: "project-123"
        ))
        #expect(!handoff.shouldDeleteCookie(
            name: "stack-access",
            domain: "example.test",
            projectID: "project-123"
        ))
        #expect(!handoff.shouldDeleteCookie(
            name: "unrelated",
            domain: "cmux.test",
            projectID: "project-123"
        ))
    }
}
