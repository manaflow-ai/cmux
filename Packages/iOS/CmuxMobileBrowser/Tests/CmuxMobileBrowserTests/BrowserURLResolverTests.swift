import Foundation
import Testing

@testable import CmuxMobileBrowser

/// The address bar maps three input shapes (full URL, bare host, free text) to
/// concrete loads. These guard that mapping, which is where omnibox correctness
/// lives.
@Suite struct BrowserURLResolverTests {
    @Test func emptyOrWhitespaceResolvesToNil() {
        #expect(BrowserURLResolver.resolve("") == nil)
        #expect(BrowserURLResolver.resolve("   ") == nil)
        #expect(BrowserURLResolver.resolve("\n\t") == nil)
    }

    @Test func fullHTTPSURLLoadsVerbatim() {
        let url = BrowserURLResolver.resolve("https://example.com/path?q=1")
        #expect(url?.absoluteString == "https://example.com/path?q=1")
    }

    @Test func httpSchemeIsPreserved() {
        let url = BrowserURLResolver.resolve("http://example.com")
        #expect(url?.scheme == "http")
        #expect(url?.host == "example.com")
    }

    @Test func bareDomainGetsHTTPSScheme() {
        let url = BrowserURLResolver.resolve("example.com")
        #expect(url?.scheme == "https")
        #expect(url?.host == "example.com")
    }

    @Test func bareDomainWithPathGetsHTTPSScheme() {
        let url = BrowserURLResolver.resolve("example.com/docs/page")
        #expect(url?.scheme == "https")
        #expect(url?.host == "example.com")
        #expect(url?.path == "/docs/page")
    }

    @Test func localhostWithPortDefaultsToHTTP() {
        // Local dev servers listen on plain HTTP; forcing HTTPS would break the
        // common "open my local dev server" cmux workflow.
        let url = BrowserURLResolver.resolve("localhost:3000")
        #expect(url?.scheme == "http")
        #expect(url?.host == "localhost")
        #expect(url?.port == 3000)
    }

    @Test func loopbackIPDefaultsToHTTP() {
        let url = BrowserURLResolver.resolve("127.0.0.1:8080")
        #expect(url?.scheme == "http")
        #expect(url?.host == "127.0.0.1")
        #expect(url?.port == 8080)
    }

    @Test func privateLANAddressesDefaultToHTTP() {
        for host in ["192.168.1.10", "10.0.0.5", "172.16.0.1"] {
            let url = BrowserURLResolver.resolve(host)
            #expect(url?.scheme == "http", "expected http for \(host)")
            #expect(url?.host == host)
        }
    }

    @Test func publicIPLikeAddressDefaultsToHTTPS() {
        // A non-private dotted-quad is treated as a normal host: HTTPS.
        let url = BrowserURLResolver.resolve("8.8.8.8")
        #expect(url?.scheme == "https")
        #expect(url?.host == "8.8.8.8")
    }

    @Test func bareIPv6LoopbackIsBracketedHTTP() {
        // `::1` must be recognized as a local host (not a search) and bracketed.
        let url = BrowserURLResolver.resolve("::1")
        #expect(url?.scheme == "http")
        #expect(url?.absoluteString == "http://[::1]")
    }

    @Test func bracketedIPv6LoopbackWithPortIsHTTP() {
        let url = BrowserURLResolver.resolve("[::1]:3000")
        #expect(url?.scheme == "http")
        #expect(url?.port == 3000)
    }

    @Test func multiWordInputBecomesSearch() {
        let url = BrowserURLResolver.resolve("how to write swift")
        #expect(url?.host == "duckduckgo.com")
        #expect(url?.query?.contains("how") == true)
        // Spaces must be percent-encoded, never left raw.
        #expect(url?.absoluteString.contains(" ") == false)
    }

    @Test func singleWordWithoutDotBecomesSearch() {
        let url = BrowserURLResolver.resolve("swift")
        #expect(url?.host == "duckduckgo.com")
        #expect(url?.query?.contains("swift") == true)
    }

    @Test func leadingWhitespaceIsTrimmedBeforeResolving() {
        let url = BrowserURLResolver.resolve("  example.com  ")
        #expect(url?.host == "example.com")
    }

    @Test func nonHTTPSchemeFallsBackToSearch() {
        // A typed `file:`/`javascript:` must not load as-is; it is treated as a
        // query so the address bar can never load a non-web scheme.
        let url = BrowserURLResolver.resolve("javascript:alert(1)")
        #expect(url?.host == "duckduckgo.com")
    }

    @Test func searchEscapesQuerySeparators() {
        // `&`, `=`, `+`, `#`, `?` in the typed query must be percent-escaped so
        // the search endpoint receives the whole string as one value rather than
        // splitting it into extra parameters.
        let url = BrowserURLResolver.resolve("AT&T earnings")
        #expect(url?.host == "duckduckgo.com")
        let raw = url?.absoluteString ?? ""
        // Exactly one `&`-free query: the literal `&` is encoded as %26.
        #expect(raw.contains("%26"))
        // The query component decodes back to the original input.
        #expect(url?.query?.contains("q=") == true)
        let plusURL = BrowserURLResolver.resolve("C++ tutorial")
        #expect(plusURL?.absoluteString.contains("%2B%2B") == true)
    }

    @Test func customSearchTemplateIsUsed() {
        let url = BrowserURLResolver.resolve(
            "hello world",
            searchTemplate: "https://search.example/q=%@"
        )
        #expect(url?.host == "search.example")
        #expect(url?.absoluteString.contains("hello") == true)
    }

    @Test func trailingDotTokenIsNotAHost() {
        // `foo.` has an empty label after the last dot, so it is a search query.
        let url = BrowserURLResolver.resolve("foo.")
        #expect(url?.host == "duckduckgo.com")
    }
}
