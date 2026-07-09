import Foundation
import Testing

@testable import CmuxCommandPalette

@Suite struct GlobalSearchNeedleResolverTests {
    private let resolver = GlobalSearchNeedleResolver()

    private func hit(
        snippet: String = "",
        title: String = "",
        location: String = "",
        anchor: String = ""
    ) -> GlobalSearchNeedleResolver.HitText {
        GlobalSearchNeedleResolver.HitText(
            snippet: snippet,
            title: title,
            location: location,
            anchor: anchor
        )
    }

    @Test func emptyTokensYieldNil() {
        #expect(resolver.needle(tokens: [], hitText: hit(snippet: "anything")) == nil)
    }

    @Test func returnsFirstTokenContainedInCombinedText() {
        // "alpha" is not in the hit text; "beta" is, so it wins over "alpha".
        let result = resolver.needle(
            tokens: ["alpha", "beta"],
            hitText: hit(snippet: "the beta release")
        )
        #expect(result == "beta")
    }

    @Test func fallsBackToFirstTokenWhenNoneMatch() {
        let result = resolver.needle(
            tokens: ["zeta", "omega"],
            hitText: hit(snippet: "nothing relevant here")
        )
        #expect(result == "zeta")
    }

    @Test func matchesAcrossAllFourFieldsAfterLowercasing() {
        // Each token appears in a different field; the FIRST token that matches
        // any field (combined + lowercased) is returned.
        #expect(
            resolver.needle(tokens: ["ANCHOR"], hitText: hit(anchor: "Anchor Section")) == "ANCHOR"
        )
        #expect(
            resolver.needle(tokens: ["loc"], hitText: hit(location: "LOCation/path")) == "loc"
        )
    }

    @Test func combinedFieldsAreJoinedSoCrossFieldSubstringsDoNotLeak() {
        // "ab" must not match across the snippet/title boundary ("...a" + "b...")
        // because the fields are joined by a newline. It falls back to token[0].
        let result = resolver.needle(
            tokens: ["ab"],
            hitText: hit(snippet: "a", title: "b")
        )
        #expect(result == "ab")
    }
}
