#if os(iOS)
import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// A closed incoming message previews as its first line of text, never as Markdown syntax: the
/// collapsed line is all the reader sees until they open it (Leo, 2026-11-17: "collapse the agent
/// messages that come in by default").
@MainActor
@Suite struct AgentIncomingPreviewTests {
    @Test func aCodeFenceIsSkippedForTheFirstLineInsideIt() {
        #expect(AgentIncomingCard.firstLine("```swift\nlet x = 1\n```") == "let x = 1")
        #expect(AgentIncomingCard.firstLine("~~~\nmake test\n~~~") == "make test")
    }

    @Test func textAfterAFenceIsShownWhenTheFenceComesFirst() {
        #expect(AgentIncomingCard.firstLine("```\n```\nDone, see above") == "Done, see above")
    }

    @Test func headingsQuotesBulletsAndNumbersLoseTheirMarks() {
        #expect(AgentIncomingCard.firstLine("## Status") == "Status")
        #expect(AgentIncomingCard.firstLine("> quoted reply") == "quoted reply")
        #expect(AgentIncomingCard.firstLine("- first item\n- second") == "first item")
        #expect(AgentIncomingCard.firstLine("1. step one") == "step one")
    }

    @Test func aLinkShowsItsText() {
        #expect(AgentIncomingCard.firstLine("See [the PR](https://example.com/pr/1) now") == "See the PR now")
    }

    @Test func emphasisAndCodeMarksGo() {
        #expect(AgentIncomingCard.firstLine("**Fixed** the `build`") == "Fixed the build")
    }

    @Test func blankAndMarkOnlyLinesAreSkipped() {
        #expect(AgentIncomingCard.firstLine("\n   \n---\n**\nReal text") == "Real text")
        #expect(AgentIncomingCard.firstLine("***\nAfter a rule") == "After a rule")
        #expect(AgentIncomingCard.firstLine("   \n**\nReal text") == "Real text")
        #expect(AgentIncomingCard.firstLine("") == "")
    }

    @Test func aTableShowsItsHeaderCells() {
        #expect(AgentIncomingCard.firstLine("| Area | Result |\n|---|---|\n| dialer | ok |") == "Area · Result")
        #expect(AgentIncomingCard.firstLine("| **Area** | `Result` |\n| :-- | --: |") == "Area · Result")
    }

    @Test func aTaskListShowsItsFirstItemWithoutTheBox() {
        #expect(AgentIncomingCard.firstLine("- [ ] todo item\n- [x] done") == "todo item")
        #expect(AgentIncomingCard.firstLine("- [x] shipped it") == "shipped it")
    }

    @Test func displayMathIsSkippedForTheTextAfterIt() {
        #expect(AgentIncomingCard.firstLine("$$\nE = mc^2\n$$\nThe energy") == "The energy")
        #expect(AgentIncomingCard.firstLine("$$x^2$$\nSquared") == "Squared")
    }

    @Test func strikethroughLosesItsTildes() {
        #expect(AgentIncomingCard.firstLine("~~struck~~ text") == "struck text")
    }

    @Test func underscoresInsideANameStay() {
        #expect(AgentIncomingCard.firstLine("Renamed fetch_with_retry to fetch") == "Renamed fetch_with_retry to fetch")
        #expect(AgentIncomingCard.firstLine("_Done_ with `max_rows`") == "Done with max_rows")
    }

    @Test func marksThatSpanALineBreakAreReadWhole() {
        #expect(AgentIncomingCard.firstLine("**Summary:\nall green**") == "Summary:")
        #expect(AgentIncomingCard.firstLine("See [the\nPR](https://example.com/pr/1) now") == "See the")
    }

    @Test func aQuoteIsReadAsTheMarkdownInsideIt() {
        #expect(AgentIncomingCard.firstLine("> ```swift\n> let x = 1\n> ```") == "let x = 1")
        #expect(AgentIncomingCard.firstLine("> ## Quoted heading\n> body") == "Quoted heading")
    }

    @Test func inlineMathLosesItsDollars() {
        #expect(AgentIncomingCard.firstLine("$x^2$ is the square") == "x^2 is the square")
        #expect(AgentIncomingCard.firstLine("It costs $5 and $6") == "It costs $5 and $6")
    }

    @Test func aListItemIsReadAsTheMarkdownInsideIt() {
        #expect(AgentIncomingCard.firstLine("- ## Heading in a list") == "Heading in a list")
        #expect(AgentIncomingCard.firstLine("- ```swift\n  let x = 1\n  ```") == "let x = 1")
        #expect(AgentIncomingCard.firstLine("1. Install:\n   ```bash\n   brew install xcodegen\n   ```") == "Install:")
    }

    @Test func aHeadingsClosingMarksAndALoneHashGo() {
        #expect(AgentIncomingCard.firstLine("## Status ##") == "Status")
        #expect(AgentIncomingCard.firstLine("#\nText") == "Text")
    }

    /// A quote or list item is read as the Markdown it holds, and that can nest without end: a
    /// message of 3,000 `>` must preview on a phone's 1 MB main-thread stack, and fast.
    @Test func deepNestingPreviewsWithinAPhonesStack() async {
        let cases = [(String(repeating: ">", count: 3000) + "text", "text"),
                     (String(repeating: "> ", count: 3000) + "spaced", "spaced"),
                     (String(repeating: "- ", count: 3000) + "item", "item"),
                     (String(repeating: "> - ", count: 1500) + "mixed", "mixed")]
        let previews: [String] = await withCheckedContinuation { done in
            let thread = Thread {
                done.resume(returning: cases.map { AgentIncomingCard.firstLine($0.0) })
            }
            thread.stackSize = 1 << 20
            thread.start()
        }
        #expect(previews == cases.map(\.1))
    }

    /// Past the levels it reads one by one, a heading or fence at the bottom still loses its marks.
    @Test func aHeadingOrFenceUnderDeepNestingLosesItsMarks() {
        #expect(AgentIncomingCard.firstLine("> > > > ## Status") == "Status")
        #expect(AgentIncomingCard.firstLine("> > > > > > ## Six deep") == "Six deep")
        #expect(AgentIncomingCard.firstLine("> > > > ```swift\n> > > > let x = 1\n> > > > ```") == "let x = 1")
        #expect(AgentIncomingCard.firstLine("- - - - ## Status") == "Status")
        #expect(AgentIncomingCard.firstLine(">>>> ## four tight") == "four tight")
        #expect(AgentIncomingCard.firstLine("> - > - ## Mixed four") == "Mixed four")
        #expect(AgentIncomingCard.firstLine(String(repeating: "> ", count: 3000) + "## Deep heading") == "Deep heading")
        #expect(AgentIncomingCard.firstLine(String(repeating: ">", count: 50) + " **bold** text") == "bold text")
    }

    @Test func plainTextIsUnchanged() {
        #expect(AgentIncomingCard.firstLine("Reviewed #45282, two nits\nmore") == "Reviewed #45282, two nits")
    }
}
#endif
