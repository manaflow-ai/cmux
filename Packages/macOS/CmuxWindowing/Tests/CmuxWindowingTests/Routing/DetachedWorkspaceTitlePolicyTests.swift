import Testing
@testable import CmuxWindowing

@Suite("DetachedWorkspaceTitlePolicy")
struct DetachedWorkspaceTitlePolicyTests {
    private let policy = DetachedWorkspaceTitlePolicy()

    @Test("prefers a non-empty explicit title verbatim after trimming")
    func prefersExplicitTitle() {
        #expect(
            policy.title(
                explicitTitle: "  Build  ",
                surfaceTitle: "Surface",
                localizedFallback: "Tab"
            ) == "Build"
        )
    }

    @Test("falls back to the surface title when the explicit title is nil")
    func nilExplicitFallsBackToSurface() {
        #expect(
            policy.title(
                explicitTitle: nil,
                surfaceTitle: "  Surface  ",
                localizedFallback: "Tab"
            ) == "Surface"
        )
    }

    @Test("treats a whitespace-only explicit title as unusable")
    func whitespaceExplicitFallsBackToSurface() {
        #expect(
            policy.title(
                explicitTitle: "   \n  ",
                surfaceTitle: "Surface",
                localizedFallback: "Tab"
            ) == "Surface"
        )
    }

    @Test("treats an empty explicit title as unusable")
    func emptyExplicitFallsBackToSurface() {
        #expect(
            policy.title(
                explicitTitle: "",
                surfaceTitle: "Surface",
                localizedFallback: "Tab"
            ) == "Surface"
        )
    }

    @Test("returns the localized fallback when both candidates trim to empty")
    func bothEmptyReturnsLocalizedFallback() {
        #expect(
            policy.title(
                explicitTitle: "  ",
                surfaceTitle: "   ",
                localizedFallback: "Tab"
            ) == "Tab"
        )
    }

    @Test("returns the localized fallback for a non-English locale string")
    func returnsNonEnglishFallback() {
        #expect(
            policy.title(
                explicitTitle: nil,
                surfaceTitle: "",
                localizedFallback: "タブ"
            ) == "タブ"
        )
    }
}
