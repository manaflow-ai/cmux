import AppKit
import Foundation
import Testing

@testable import CmuxBrowser

@Suite(.serialized) struct BrowserURLResolverTests {
    private let resolver = BrowserURLResolver()

    @Test func resolvesWrappedOAuthURLWithoutRewriting() throws {
        let expected =
            "https://auth.openai.com/oauth/authorize?client_id=app_123" +
            "&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fcallback" +
            "&scope=openid%20profile&state=abc123"
        let wrapped = expected.replacingOccurrences(of: "&scope=", with: "&\nscope=")

        #expect(try #require(resolver.navigableURL(from: wrapped)).absoluteString == expected)
    }

    @Test func preparesWrappedPasteBeforeSingleLineFieldRewritesIt() {
        let expected = "https://example.com/callback?scope=openid%20profile&state=abc123"
        let wrapped = expected.replacingOccurrences(of: "&state=", with: "&\tstate=")

        #expect(resolver.textForPaste(wrapped) == expected)
    }

    @Test @MainActor func fieldEditorSanitizesStandardPastePath() throws {
        let expected = "https://example.com/callback?scope=openid%20profile&state=abc123"
        let wrapped = expected.replacingOccurrences(of: "&state=", with: "&\nstate=")
        let padded = "  \n\t\(wrapped)\r\n  "
        let pasteboard = NSPasteboard(name: .init("cmux.omnibar.tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(padded, forType: .string)
        let cell = BrowserOmnibarPasteTextFieldCell(textCell: "")
        let editor = try #require(
            cell.fieldEditor(for: NSView()) as? BrowserOmnibarPasteFieldEditor
        )

        #expect(
            editor.tryToPerform(
                #selector(NSTextView.readSelection(from:)),
                with: pasteboard
            )
        )
        #expect(editor.string == expected)
        #expect(cell.isEditable)
        #expect(cell.isSelectable)
    }

    @Test @MainActor func fieldEditorSanitizesTypeSpecificPastePath() throws {
        let expected = "https://example.com/callback?scope=openid%20profile&state=abc123"
        let wrapped = expected.replacingOccurrences(of: "&state=", with: "&\nstate=")
        let pasteboard = NSPasteboard(name: .init("cmux.omnibar.tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(wrapped, forType: .string)
        let cell = BrowserOmnibarPasteTextFieldCell(textCell: "")
        let editor = try #require(
            cell.fieldEditor(for: NSView()) as? BrowserOmnibarPasteFieldEditor
        )

        #expect(editor.readSelection(from: pasteboard, type: .string))
        #expect(editor.string == expected)
    }

    @Test func preservesMeaningfulSpacesInExplicitURLsAndSearchTerms() throws {
        let queryWithSpace = "https://example.com/search?q=hello world"
        let resolvedURL = try #require(resolver.navigableURL(from: queryWithSpace))

        #expect(resolver.textForPaste(queryWithSpace) == queryWithSpace)
        #expect(resolvedURL.host == "example.com")
        #expect(
            URLComponents(url: resolvedURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first?.value == "hello world"
        )
        #expect(resolver.navigableURL(from: "a b.com/path?x=1") == nil)
        #expect(resolver.navigableURL(from: "go\texample.com/path") == nil)
        #expect(resolver.navigableURL(from: "go\nexample.com/path") == nil)
    }

    /// Foundation encodes a URL component that holds raw Unicode as if none of
    /// it were encoded yet, so a `%2F` beside Japanese text used to reach the
    /// page as `%252F` (manaflow-ai/cmux#40300). Browsers keep it.
    @Test func keepsPercentEscapesThatSitNextToRawUnicode() throws {
        let explicit = try #require(
            resolver.navigableURL(from: "https://scrapbox.io/example-project/会議メモ_2026%2F11%2F5#section")
        )
        #expect(
            explicit.absoluteString ==
                "https://scrapbox.io/example-project/%E4%BC%9A%E8%AD%B0%E3%83%A1%E3%83%A2_2026%2F11%2F5#section"
        )

        let schemeLess = try #require(
            resolver.navigableURL(from: "scrapbox.io/example-project/会議メモ_2026%2F11%2F5")
        )
        #expect(
            schemeLess.absoluteString ==
                "https://scrapbox.io/example-project/%E4%BC%9A%E8%AD%B0%E3%83%A1%E3%83%A2_2026%2F11%2F5"
        )

        let spacedQuery = try #require(
            resolver.navigableURL(from: "https://example.com/search?q=日本 語&next=a%2Fb")
        )
        #expect(
            spacedQuery.absoluteString ==
                "https://example.com/search?q=%E6%97%A5%E6%9C%AC%20%E8%AA%9E&next=a%2Fb"
        )
    }

    @Test func stillEncodesCharactersURLsCannotCarryNextToRawUnicode() throws {
        #expect(
            try #require(resolver.navigableURL(from: "https://example.com/日本100%")).absoluteString ==
                "https://example.com/%E6%97%A5%E6%9C%AC100%25"
        )
        #expect(
            try #require(resolver.navigableURL(from: "https://example.com/メモ|a")).absoluteString ==
                "https://example.com/%E3%83%A1%E3%83%A2%7Ca"
        )
        #expect(
            try #require(resolver.navigableURL(from: "https://example.com/a#メモ#b")).absoluteString ==
                "https://example.com/a#%E3%83%A1%E3%83%A2%23b"
        )
    }

    @Test func doesNotCompactTextThatConstructsADifferentAuthority() {
        let explicitInput = "https://trusted.example\n@evil.example/path"
        let schemeLessInput = "trusted.example\n@evil.example/path"

        #expect(resolver.textForPaste(explicitInput) == explicitInput)
        #expect(resolver.navigableURL(from: explicitInput) == nil)
        #expect(
            resolver.navigableURL(from: explicitInput.replacingOccurrences(of: "\n", with: " ")) == nil
        )
        #expect(resolver.textForPaste(schemeLessInput) == schemeLessInput)
        #expect(resolver.navigableURL(from: schemeLessInput) == nil)
    }

    @Test func preservesExistingNavigationAndSearchBoundaries() throws {
        #expect(try #require(resolver.navigableURL(from: "localhost:3000")).absoluteString == "http://localhost:3000")
        #expect(
            try #require(resolver.navigableURL(from: "example.com/path?x=1")).absoluteString ==
                "https://example.com/path?x=1"
        )
        #expect(resolver.navigableURL(from: "example.\ncom/path?x=1") == nil)
        #expect(
            try #require(resolver.navigableURL(from: "example.com/path?\nx=1")).absoluteString ==
                "https://example.com/path?x=1"
        )
        #expect(resolver.navigableURL(from: "node.js tutorial") == nil)
        #expect(resolver.navigableURL(from: "node.js\ttutorial") == nil)
    }

    @Test func onlyLoopbackHostsDefaultToHTTP() throws {
        #expect(try #require(resolver.navigableURL(from: "localhost:3000")).scheme == "http")
        #expect(try #require(resolver.navigableURL(from: "dev.localhost:3000")).scheme == "http")
        #expect(try #require(resolver.navigableURL(from: "[::1]:3000")).scheme == "http")
        #expect(try #require(resolver.navigableURL(from: "127.0.0.10:3000")).scheme == "http")
        #expect(try #require(resolver.navigableURL(from: "localhost.evil.com")).scheme == "https")
        #expect(try #require(resolver.navigableURL(from: "127.0.0.1.evil.com")).scheme == "https")
        #expect(resolver.navigableURL(from: "localhost:80@evil.example/path") == nil)
        #expect(resolver.navigableURL(from: "127.0.0.1:80@evil.example") == nil)
        #expect(
            try #require(resolver.navigableURL(from: "example.com/path?email=user@example.com")).host ==
                "example.com"
        )
    }

    @Test func authorityUserInfoIsRejectedEvenWhenLaterTextLooksLikeAScheme() {
        #expect(resolver.navigableURL(from: "localhost:80@evil.example/path?u=http://x") == nil)
        #expect(resolver.navigableURL(from: "localhost:80@evil.example/path#http://x") == nil)
        #expect(resolver.navigableURL(from: "localhost:80@evil.example") == nil)
        #expect(resolver.navigableURL(from: "user@evil.example") == nil)
        #expect(resolver.navigableURL(from: "user@evil.example/?next=https://x") == nil)
    }

    @Test func pathAndQueryDataDoNotAffectTheResolvedHost() throws {
        let local = try #require(resolver.navigableURL(from: "localhost:3000/a?next=http://x"))
        #expect(local.absoluteString == "http://localhost:3000/a?next=http://x")
        #expect(local.host == "localhost")
        #expect(local.user == nil)

        let atPath = try #require(resolver.navigableURL(from: "example.com/@user"))
        #expect(atPath.absoluteString == "https://example.com/@user")
        #expect(atPath.host == "example.com")

        let atQuery = try #require(resolver.navigableURL(from: "example.com?x=a@b"))
        #expect(atQuery.absoluteString == "https://example.com?x=a@b")
        #expect(atQuery.host == "example.com")

        let portQuery = try #require(resolver.navigableURL(from: "example.com:8443/a?x=a@b&u=http://y"))
        #expect(portQuery.host == "example.com")
        #expect(portQuery.port == 8443)
    }

    @Test func preservesSupportedAndRejectedSchemes() throws {
        #expect(try #require(resolver.navigableURL(from: "file:///tmp/example.html")).isFileURL)
        #expect(resolver.navigableURL(from: "mailto:test@example.com") == nil)
        #expect(resolver.navigableURL(from: "ftp://example.com/file.html") == nil)
    }

    @Test func resolvesBareAbsolutePOSIXPathAsFileURL() throws {
        let resolved = try #require(resolver.navigableURL(from: "/Users/x/y.html"))

        #expect(resolved.isFileURL)
        #expect(resolved.path == "/Users/x/y.html")
        #expect(resolved.absoluteString == "file:///Users/x/y.html")
    }

    @Test func resolvesBareAbsolutePathWithSpacesAsFileURL() throws {
        let resolved = try #require(resolver.navigableURL(from: "/tmp/a b/c.html"))

        #expect(resolved.isFileURL)
        #expect(resolved.path == "/tmp/a b/c.html")
        #expect(resolved.absoluteString == "file:///tmp/a%20b/c.html")
    }

    @Test func resolvesTildePathAsFileURL() throws {
        let homeDirectoryURL = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let resolver = BrowserURLResolver(homeDirectoryURL: homeDirectoryURL)
        let resolved = try #require(resolver.navigableURL(from: "~/Desktop/report.html"))
        let expectedPath = homeDirectoryURL
            .appending(path: "Desktop/report.html")
            .path

        #expect(resolved.isFileURL)
        #expect(resolved.path == expectedPath)
    }

    @Test func preservesExplicitFileURLWithSpaces() throws {
        let resolved = try #require(resolver.navigableURL(from: "file:///tmp/a b/c.html"))

        #expect(resolved.isFileURL)
        #expect(resolved.path == "/tmp/a b/c.html")
    }
}
