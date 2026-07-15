import Foundation
import Testing
@testable import CmuxBrowser

@Suite struct ChromiumBrowserCookieCodecTests {
    @Test func decodesPersistentAndSessionCookies() throws {
        let codec = ChromiumBrowserCookieCodec()
        let response = CDPJSONValue.object([
            "cookies": .array([
                .object([
                    "name": .string("persistent"),
                    "value": .string("one"),
                    "domain": .string(".example.com"),
                    "path": .string("/account"),
                    "secure": .bool(true),
                    "httpOnly": .bool(true),
                    "expires": .number(2_000_000_000),
                ]),
                .object([
                    "name": .string("session"),
                    "value": .string("two"),
                    "domain": .string("example.com"),
                    "path": .string("/"),
                    "secure": .bool(false),
                    "httpOnly": .bool(false),
                    "expires": .number(-1),
                ]),
            ]),
        ])

        let cookies = try codec.cookies(from: response)

        #expect(cookies.count == 2)
        #expect(cookies[0].name == "persistent")
        #expect(cookies[0].isSecure)
        #expect(cookies[0].isHTTPOnly)
        #expect(cookies[0].expiresDate == Date(timeIntervalSince1970: 2_000_000_000))
        #expect(cookies[1].name == "session")
        #expect(cookies[1].isSessionOnly)
    }

    @Test func encodesSetAndDeleteParameters() {
        let codec = ChromiumBrowserCookieCodec()
        let cookie = BrowserEngineCookie(
            name: "session",
            value: "value",
            domain: ".example.com",
            path: "/account",
            isSecure: true,
            isHTTPOnly: true,
            expiresDate: Date(timeIntervalSince1970: 2_000_000_000)
        )

        let setParameters = codec.setParameters(for: cookie)
        let deleteParameters = codec.deleteParameters(for: cookie)

        #expect(setParameters["name"] == .string("session"))
        #expect(setParameters["value"] == .string("value"))
        #expect(setParameters["secure"] == .bool(true))
        #expect(setParameters["httpOnly"] == .bool(true))
        #expect(setParameters["expires"] == .number(2_000_000_000))
        #expect(deleteParameters == [
            "name": .string("session"),
            "domain": .string(".example.com"),
            "path": .string("/account"),
        ])
    }

    @Test func rejectsMalformedCookieRowsInsteadOfReturningPartialState() {
        let codec = ChromiumBrowserCookieCodec()
        let response = CDPJSONValue.object([
            "cookies": .array([
                .object([
                    "name": .string("complete"),
                    "value": .string("one"),
                    "domain": .string("example.com"),
                    "path": .string("/"),
                ]),
                .object([
                    "name": .string("missing-domain"),
                    "value": .string("two"),
                    "path": .string("/"),
                ]),
            ]),
        ])

        #expect(throws: BrowserEngineSessionError.self) {
            try codec.cookies(from: response)
        }
    }
}
