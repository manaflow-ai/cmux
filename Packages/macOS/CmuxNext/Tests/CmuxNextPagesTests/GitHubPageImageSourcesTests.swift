@testable import CmuxNextPages
import Testing

/// The GitHub page loads a body's images only through GitHub's image proxy (camo) and its signed
/// attachment links; every other page keeps `img-src 'self' data:`.
struct GitHubPageImageSourcesTests {
    private func imageSources(_ policy: String) -> [String] {
        let directive = policy.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("img-src ") } ?? ""
        return directive.split(separator: " ").dropFirst().map(String.init)
    }

    @Test func theGitHubPageAddsOnlyGitHubsImageHosts() {
        let sources = imageSources(PageDescriptor.github.csp.header)
        #expect(sources == ["'self'", "data:"] + PageDescriptor.githubImageSources)
        #expect(sources.allSatisfy { $0 == "'self'" || $0 == "data:" || $0.hasSuffix(".githubusercontent.com") })
        #expect(!sources.contains("https:"))
    }

    @Test func anotherPageKeepsTheStrictImagePolicy() {
        #expect(imageSources(PageCSP.strict.header) == ["'self'", "data:"])
        #expect(imageSources(PageDescriptor.markdown.csp.header) == ["'self'", "data:"])
        // A source that could split the directive is dropped.
        #expect(imageSources(PageCSP(image: ["https://a.example; script-src *", ""]).header) == ["'self'", "data:"])
    }

    @Test func onlyABuiltInPageMayAddImageSourcesAndNothingElse() {
        let wide = PageCSP(connect: ["https://a.example"], image: ["https://camo.githubusercontent.com"])
        let app = PageDescriptor(id: "com.example.app", resource: "app", namespaces: [], csp: wide)
        #expect(app.csp.header == PageCSP.strict.header)
        let builtIn = PageDescriptor(id: "cmux.github-test", resource: "github", namespaces: [], csp: wide)
        #expect(imageSources(builtIn.csp.header) == ["'self'", "data:", "https://camo.githubusercontent.com"])
        #expect(!builtIn.csp.header.contains("connect-src"))
    }

    /// Review follow-up on #38075 (F2): a built-in page's own narrowing stands. Taking its image
    /// sources must not reset inline script, which only narrows the policy, back to allowed.
    @Test func aBuiltInPageThatTurnsInlineScriptOffKeepsItOff() {
        let narrow = PageCSP(image: ["https://camo.githubusercontent.com"], inlineScript: false)
        let builtIn = PageDescriptor(id: "cmux.github-test", resource: "github", namespaces: [], csp: narrow)
        #expect(builtIn.csp.inlineScript == false)
        #expect(builtIn.csp.header.contains("script-src 'self';"))
        #expect(imageSources(builtIn.csp.header) == ["'self'", "data:", "https://camo.githubusercontent.com"])
        // Nothing else of the page's policy comes along.
        let wide = PageCSP(connect: ["https://a.example"], frame: ["https://b.example"], media: ["https://c.example"],
                           script: ["'wasm-unsafe-eval'"], inlineScript: false)
        let kept = PageDescriptor(id: "cmux.github-test", resource: "github", namespaces: [], csp: wide).csp
        #expect(kept == PageCSP(inlineScript: false))
    }
}
