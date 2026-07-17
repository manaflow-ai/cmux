import Testing
@testable import CmuxDiffUI

@Suite struct DiffPromptFormatterTests {
    @Test func includesFileLineReferencesFenceExcerptAndMultilineNote() {
        let prompt = DiffPromptFormatter().format(
            target: target(
                path: "Sources/App.swift",
                old: 10...12,
                new: 10...13,
                excerpt: "@@ -10,3 +10,4 @@ render\n-old\n+new"
            ),
            note: "Check the behavior.\nKeep the API stable."
        )

        #expect(prompt.contains("New target: Sources/App.swift:10-13"))
        #expect(prompt.contains("Old target: Sources/App.swift:10-12"))
        #expect(prompt.contains("```diff\n@@ -10,3 +10,4 @@ render\n-old\n+new\n```"))
        #expect(prompt.hasSuffix("Check the behavior.\nKeep the API stable."))
    }

    @Test func preservesUnicodePathAndEscapesEmbeddedNewline() {
        let prompt = DiffPromptFormatter().format(
            target: target(path: "資料/こんにちは\n画面.swift", old: nil, new: 7...7, excerpt: "+値"),
            note: "確認"
        )

        #expect(prompt.contains("資料/こんにちは\\n画面.swift:7"))
        #expect(prompt.contains("+値"))
        #expect(prompt.hasSuffix("確認"))
    }

    @Test func fenceExpandsPastBackticksInsideExcerpt() {
        let prompt = DiffPromptFormatter().format(
            target: target(path: "README.md", old: 1...1, new: 1...1, excerpt: "+```swift\n+let x = 1\n+```"),
            note: ""
        )

        #expect(prompt.contains("````diff\n+```swift"))
        #expect(prompt.contains("+```\n````"))
    }

    @Test func truncatesLongExcerptWithoutSplittingUnicodeCharacters() {
        let prompt = DiffPromptFormatter(maximumExcerptCharacters: 80).format(
            target: target(
                path: "Sources/長い.swift",
                old: 1...200,
                new: 1...200,
                excerpt: String(repeating: "+🧪test\n", count: 100)
            ),
            note: "short"
        )

        #expect(prompt.contains("… [excerpt truncated]"))
        #expect(!prompt.contains(String(repeating: "+🧪test\n", count: 20)))
        #expect(prompt.hasSuffix("short"))
    }

    private func target(
        path: String,
        old: ClosedRange<Int>?,
        new: ClosedRange<Int>?,
        excerpt: String
    ) -> DiffQuickNoteTarget {
        DiffQuickNoteTarget(
            id: "target",
            path: path,
            oldLineRange: old,
            newLineRange: new,
            hunkHeader: "@@ target @@",
            excerpt: excerpt
        )
    }
}
