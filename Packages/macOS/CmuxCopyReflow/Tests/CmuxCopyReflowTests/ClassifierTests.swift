@testable import CmuxCopyReflow
import Testing

@Suite
struct ClassifierTests {
    private func classify(_ line: String, activeFence: FenceMarker? = nil) -> LineKind {
        LineKind(line[...], activeFence: activeFence)
    }

    @Test func fenceDelimiters() {
        #expect(classify("```") == .fenceDelimiter)
        #expect(classify("```swift") == .fenceDelimiter)
        #expect(classify("~~~") == .fenceDelimiter)
    }

    @Test func insideFenceOverridesContent() throws {
        let fence = try #require(FenceMarker(trimmedLine: "```"[...]))
        // A heading-looking or bullet-looking line inside a fence stays code.
        #expect(classify("## not a heading", activeFence: fence) == .insideFence)
        #expect(classify("- not a bullet", activeFence: fence) == .insideFence)
    }

    @Test func insideFenceOnlyMatchingMarkerCloses() throws {
        let backtickFence = try #require(FenceMarker(trimmedLine: "```"[...]))
        let tildeFence = try #require(FenceMarker(trimmedLine: "~~~"[...]))

        #expect(classify("~~~", activeFence: backtickFence) == .insideFence)
        #expect(classify("```", activeFence: tildeFence) == .insideFence)
        #expect(classify("``", activeFence: backtickFence) == .insideFence)
        #expect(classify("``` not closing", activeFence: backtickFence) == .insideFence)
        #expect(classify("```", activeFence: backtickFence) == .fenceDelimiter)
        #expect(classify("````", activeFence: backtickFence) == .fenceDelimiter)
    }

    @Test func headings() {
        #expect(classify("# H1") == .heading)
        #expect(classify("###### H6") == .heading)
        #expect(classify("### ") == .heading)
    }

    @Test func hashWithoutSpaceIsProse() {
        #expect(classify("#nothashtag") == .prose)
        #expect(classify("####### too many") == .prose)
    }

    @Test func blockquote() {
        #expect(classify("> quoted") == .blockquote)
    }

    @Test func arrowIsNotBlockquote() {
        #expect(classify("-> arrow") == .prose)
    }

    @Test func listItems() {
        #expect(classify("- item") == .listItem)
        #expect(classify("* item") == .listItem)
        #expect(classify("+ item") == .listItem)
        #expect(classify("• item") == .listItem)
        #expect(classify("1. item") == .listItem)
        #expect(classify("2) item") == .listItem)
    }

    @Test func listMarkerWithoutSpaceIsNotListItem() {
        #expect(classify("-dash") == .prose)
        #expect(classify("1.5 is a number") == .prose)
    }

    @Test func tableRows() {
        #expect(classify("| a | b |") == .tableRow)
        #expect(classify("|---|---|") == .tableRow)
        #expect(classify("| left | right |") == .tableRow)
        #expect(classify("---|---") == .tableRow)
        #expect(classify("left | right") == .prose)
        #expect(classify("find . | tee /tmp/out") == .prose)
    }

    @Test func urlLines() {
        #expect(classify("https://x.io/a") == .urlLine)
        #expect(classify("www.x.io") == .urlLine)
        #expect(classify("- https://x.io") == .urlLine)
        #expect(classify("> https://x.io") == .urlLine)
        #expect(classify("https://x.io needs review") == .prose)
    }

    @Test func urlMentionIsProse() {
        // "Mentions a URL" is not "is a URL".
        #expect(classify("see https://x.io here") == .prose)
    }

    @Test func decorationLineIsProse() {
        // Decoration stripping happens during reflow; classification is prose.
        #expect(classify("▶ note") == .prose)
        #expect(classify("● status") == .prose)
    }

    @Test func blank() {
        #expect(classify("") == .blank)
        #expect(classify("    ") == .blank)
        #expect(classify("\t") == .blank)
    }
}
