import CmuxTerminalCore
import Testing

@Suite("Codex tab title composer")
struct CodexTabTitleComposerTests {
    private let composer = CodexTabTitleComposer(runningMarker: "◐ ", idleMarker: "✳ ")

    @Test("running and idle states use transient markers")
    func lifecycleMarkers() {
        let running = composer.presentation(
            baseTitle: "some-name",
            lifecycle: .running,
            hasUserOwnedTitle: false
        )
        #expect(running.title == "◐ some-name")
        #expect(running.isAnimating)

        let idle = composer.presentation(
            baseTitle: "some-name",
            lifecycle: .idle,
            hasUserOwnedTitle: false
        )
        #expect(idle.title == "✳ some-name")
        #expect(!idle.isAnimating)
    }

    @Test("needs-input and unknown preserve marker-prefixed stable titles")
    func markerPrefixedStableTitleIsNotTruncated() {
        for lifecycle in [CodexTabTitleLifecycle.needsInput, .unknown] {
            let presentation = composer.presentation(
                baseTitle: "✳ release-notes",
                lifecycle: lifecycle,
                hasUserOwnedTitle: false
            )
            #expect(presentation.title == "✳ release-notes")
            #expect(!presentation.isAnimating)
        }
    }

    @Test("user-owned titles keep their text while running activity remains visible")
    func userOwnedTitlePrecedence() {
        let presentation = composer.presentation(
            baseTitle: "Pinned lane",
            lifecycle: .running,
            hasUserOwnedTitle: true
        )
        #expect(presentation.title == "Pinned lane")
        #expect(presentation.isAnimating)
    }

    @Test("auto titles are eligible for lifecycle markers")
    func autoTitleIsNotTreatedAsUserOwned() {
        let presentation = composer.presentation(
            baseTitle: "Generated lane",
            lifecycle: .running,
            hasUserOwnedTitle: false
        )
        #expect(presentation.title == "◐ Generated lane")
        #expect(presentation.isAnimating)
    }

    @Test("stable title whitespace is preserved exactly")
    func preservesStableTitleWhitespace() {
        let presentation = composer.presentation(
            baseTitle: " Generated lane ",
            lifecycle: .running,
            hasUserOwnedTitle: false
        )
        #expect(presentation.title == "◐  Generated lane ")
    }
}
