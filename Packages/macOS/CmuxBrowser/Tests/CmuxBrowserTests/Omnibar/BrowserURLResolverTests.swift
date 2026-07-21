import AppKit
import Foundation
import Testing

@testable import CmuxBrowser

@Suite struct BrowserURLResolverTests {
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

        #expect(editor.readSelection(from: pasteboard))
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
    }

    @Test func preservesExistingNavigationAndSearchBoundaries() throws {
        #expect(try #require(resolver.navigableURL(from: "localhost:3000")).absoluteString == "http://localhost:3000")
        #expect(
            try #require(resolver.navigableURL(from: "example.com/path?x=1")).absoluteString ==
                "https://example.com/path?x=1"
        )
        #expect(
            try #require(resolver.navigableURL(from: "example.\ncom/path?x=1")).absoluteString ==
                "https://example.com/path?x=1"
        )
        #expect(resolver.navigableURL(from: "node.js tutorial") == nil)
        #expect(resolver.navigableURL(from: "node.js\ttutorial") == nil)
    }

    @Test func onlyExactLoopbackHostsDefaultToHTTP() throws {
        #expect(try #require(resolver.navigableURL(from: "localhost:3000")).scheme == "http")
        #expect(try #require(resolver.navigableURL(from: "dev.localhost:3000")).scheme == "http")
        #expect(try #require(resolver.navigableURL(from: "[::1]:3000")).scheme == "http")
        #expect(try #require(resolver.navigableURL(from: "localhost.evil.com")).scheme == "https")
        #expect(try #require(resolver.navigableURL(from: "127.0.0.10")).scheme == "https")
    }

    @Test func preservesSupportedAndRejectedSchemes() throws {
        #expect(try #require(resolver.navigableURL(from: "file:///tmp/example.html")).isFileURL)
        #expect(resolver.navigableURL(from: "mailto:test@example.com") == nil)
        #expect(resolver.navigableURL(from: "ftp://example.com/file.html") == nil)
    }
}
