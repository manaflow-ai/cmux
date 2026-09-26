import Testing

@testable import CmuxMobileShellUI

@Suite("SpeakableTextFilter")
struct SpeakableTextFilterTests {
    @Test("plain prose passes through with markdown syntax stripped")
    func plainProse() {
        let input = """
        ## Done

        I **fixed** the _bug_ in the parser.
        - The cache is now invalidated.
        - Tests pass.
        """
        let output = SpeakableTextFilter().speakableText(from: input)
        #expect(output == "Done I fixed the bug in the parser. The cache is now invalidated. Tests pass.")
    }

    @Test("fenced code blocks are summarized by default")
    func codeBlockSummarized() {
        let input = """
        Here is the fix:
        ```swift
        let a = 1
        let b = 2
        let c = a + b
        print(c)
        ```
        Let me know.
        """
        let output = SpeakableTextFilter().speakableText(from: input)
        #expect(output.contains("a swift block of 4 lines"))
        #expect(!output.contains("print"))
        #expect(output.contains("Let me know."))
    }

    @Test("short code blocks are spoken when opted in")
    func codeBlockSpokenWhenOptedIn() {
        let input = """
        Run this:
        ```
        swift build
        ```
        """
        let options = SpeakableTextOptions(speakCodeBlocks: true)
        let output = SpeakableTextFilter(options: options).speakableText(from: input)
        #expect(output.contains("swift build"))
    }

    @Test("long code blocks stay summarized even when opted in")
    func longCodeBlockAlwaysSummarized() {
        let body = Array(repeating: "let x = 1", count: 30).joined(separator: "\n")
        let input = "Result:\n```swift\n\(body)\n```"
        let options = SpeakableTextOptions(speakCodeBlocks: true)
        let output = SpeakableTextFilter(options: options).speakableText(from: input)
        #expect(output.contains("a swift block of 30 lines"))
        #expect(!output.contains("let x = 1"))
    }

    @Test("diffs are summarized with a change count, never read")
    func diffSummarized() {
        let input = """
        Applied:
        ```diff
        @@ -1,3 +1,3 @@
        -let old = true
        +let new = true
        +let extra = 1
        ```
        """
        let output = SpeakableTextFilter().speakableText(from: input)
        #expect(output.contains("a diff changing 3 lines"))
        #expect(!output.contains("let old"))
    }

    @Test("a backtick fence inside a tilde block stays content")
    func mixedFences() {
        let input = """
        Patch:
        ~~~
        ```
        let hidden = true
        ~~~
        Done.
        """
        let output = SpeakableTextFilter().speakableText(from: input)
        #expect(output.contains("a code block of 2 lines"))
        #expect(!output.contains("hidden"))
        #expect(output.contains("Done."))
    }

    @Test("unterminated fences from truncated streams still summarize")
    func unterminatedFence() {
        let input = "Working on it:\n```swift\nfunc a() {}\nfunc b() {}"
        let output = SpeakableTextFilter().speakableText(from: input)
        #expect(output.contains("a swift block of 2 lines"))
        #expect(!output.contains("func a"))
    }

    @Test("tables are summarized with a row count")
    func tableSummarized() {
        let input = """
        Results:
        | name | value |
        |------|-------|
        | a    | 1     |
        | b    | 2     |
        Done.
        """
        let output = SpeakableTextFilter().speakableText(from: input)
        #expect(output.contains("a table with 3 rows"))
        #expect(!output.contains("|"))
    }

    @Test("links speak their label and bare URLs their host")
    func linksAndURLs() {
        let input = "See [the PR](https://github.com/manaflow-ai/cmux/pull/1) and https://example.com/a/b?q=1"
        let output = SpeakableTextFilter().speakableText(from: input)
        #expect(output.contains("the PR"))
        #expect(!output.contains("github.com/manaflow-ai"))
        #expect(output.contains("the link at example.com"))
    }

    @Test("long inline code is summarized, short inline code spoken")
    func inlineCode() {
        let long = String(repeating: "x", count: 80)
        let input = "Set `CMUX_PORT` from `\(long)` first."
        let output = SpeakableTextFilter().speakableText(from: input)
        #expect(output.contains("CMUX_PORT"))
        #expect(output.contains("an inline code snippet"))
        #expect(!output.contains(long))
    }

    @Test("deep file paths reduce to their basename")
    func deepPaths() {
        let input = "Edited /Users/dev/project/Sources/App/Main.swift today."
        let output = SpeakableTextFilter().speakableText(from: input)
        #expect(output.contains("the file Main.swift"))
        #expect(!output.contains("/Users/dev"))
    }

    @Test("output respects the maximum length at a sentence boundary")
    func lengthCap() {
        let sentence = "This sentence is precisely long enough to matter here. "
        let input = String(repeating: sentence, count: 30)
        let options = SpeakableTextOptions(maximumCharacters: 200)
        let output = SpeakableTextFilter(options: options).speakableText(from: input)
        #expect(output.count <= 200)
        #expect(output.hasSuffix("."))
    }

    @Test("empty and whitespace input yield empty output")
    func emptyInput() {
        #expect(SpeakableTextFilter().speakableText(from: "") == "")
        #expect(SpeakableTextFilter().speakableText(from: "  \n\n  ") == "")
    }
}
