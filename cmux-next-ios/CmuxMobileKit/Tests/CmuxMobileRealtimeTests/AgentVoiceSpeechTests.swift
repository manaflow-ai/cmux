import Foundation
import Testing
@testable import CmuxMobileRealtime

/// What voice mode reads aloud of an agent's Markdown: its words, not its code.
@Suite struct AgentVoiceSpeechTests {
    let speech = AgentVoiceSpeech()

    @Test func codeBlocksAndDiffsAreNotRead() {
        let markdown = """
        I fixed the race in the session store.

        ```swift
        let x = store.load()
        x.save()
        ```

        ```diff
        @@ -1,3 +1,3 @@
        -let a = 1
        +let a = 2
        ```

        All 43 tests pass now.
        """
        #expect(speech.speakable(markdown) == "I fixed the race in the session store. All 43 tests pass now.")
    }

    @Test func aBareDiffOutsideAFenceIsNotRead() {
        let markdown = """
        Here is the change:
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -4 +4 @@
        -old()
        +new()
        Done.
        """
        #expect(speech.speakable(markdown) == "Here is the change: Done.")
    }

    @Test func onlyCodeSaysNothing() {
        #expect(speech.speakable("```\nmake test\n```") == nil)
        #expect(speech.speakable("") == nil)
        #expect(speech.speakable("| a | b |\n|---|---|\n| 1 | 2 |") == nil)
    }

    @Test func markdownMarkersGoAndLinksKeepTheirText() {
        let markdown = """
        ## Summary
        - **Fixed** the [login bug](https://github.com/x/y/pull/1)
        - Updated `README.md` and _docs_

        ---
        See https://example.com/very/long/url for more.
        ![screenshot](shot.png)
        """
        #expect(speech.speakable(markdown) ==
            "Summary. Fixed the login bug. Updated README.md and docs. See a link for more.")
    }

    @Test func longInlineCodeIsDropped() {
        let text = "Run `xcodebuild -scheme CmuxMobileKit-Package -destination generic/platform=iOS test` again."
        #expect(speech.speakable(text) == "Run again.")
    }

    @Test func wrappedLinesJoinIntoOneSentence() {
        #expect(speech.speakable("The build failed because\nthe cache was stale.") ==
            "The build failed because the cache was stale.")
    }

    @Test func aSingleDashedListItemIsKept() {
        #expect(speech.speakable("Next:\n- rerun CI") == "Next: rerun CI.")
    }

    @Test func longTextStopsAtASentenceEnd() {
        let speech = AgentVoiceSpeech(maxCharacters: 60)
        let text = "First sentence is here. Second sentence is also here. Third sentence goes past the limit."
        #expect(speech.speakable(text) == "First sentence is here. Second sentence is also here.")
    }
}
