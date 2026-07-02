@testable import CmuxCopyReflow
import XCTest

final class ClassifierTests: XCTestCase {
    private func classify(_ line: String, insideFence: Bool = false) -> LineKind {
        LineClassifier.classify(line[...], insideFence: insideFence)
    }

    func testFenceDelimiters() {
        XCTAssertEqual(classify("```"), .fenceDelimiter)
        XCTAssertEqual(classify("```swift"), .fenceDelimiter)
        XCTAssertEqual(classify("~~~"), .fenceDelimiter)
    }

    func testInsideFenceOverridesContent() {
        // A heading-looking or bullet-looking line inside a fence stays code.
        XCTAssertEqual(classify("## not a heading", insideFence: true), .insideFence)
        XCTAssertEqual(classify("- not a bullet", insideFence: true), .insideFence)
    }

    func testHeadings() {
        XCTAssertEqual(classify("# H1"), .heading)
        XCTAssertEqual(classify("###### H6"), .heading)
        XCTAssertEqual(classify("### "), .heading)
    }

    func testHashWithoutSpaceIsProse() {
        XCTAssertEqual(classify("#nothashtag"), .prose)
        XCTAssertEqual(classify("####### too many"), .prose)
    }

    func testBlockquote() {
        XCTAssertEqual(classify("> quoted"), .blockquote)
    }

    func testArrowIsNotBlockquote() {
        XCTAssertEqual(classify("-> arrow"), .prose)
    }

    func testListItems() {
        XCTAssertEqual(classify("- item"), .listItem)
        XCTAssertEqual(classify("* item"), .listItem)
        XCTAssertEqual(classify("+ item"), .listItem)
        XCTAssertEqual(classify("• item"), .listItem)
        XCTAssertEqual(classify("1. item"), .listItem)
        XCTAssertEqual(classify("2) item"), .listItem)
    }

    func testListMarkerWithoutSpaceIsNotListItem() {
        XCTAssertEqual(classify("-dash"), .prose)
        XCTAssertEqual(classify("1.5 is a number"), .prose)
    }

    func testTableRows() {
        XCTAssertEqual(classify("| a | b |"), .tableRow)
        XCTAssertEqual(classify("|---|---|"), .tableRow)
        XCTAssertEqual(classify("| left | right |"), .tableRow)
    }

    func testURLLines() {
        XCTAssertEqual(classify("https://x.io/a"), .urlLine)
        XCTAssertEqual(classify("www.x.io"), .urlLine)
        XCTAssertEqual(classify("- https://x.io"), .urlLine)
        XCTAssertEqual(classify("> https://x.io"), .urlLine)
    }

    func testURLMentionIsProse() {
        // "Mentions a URL" is not "is a URL".
        XCTAssertEqual(classify("see https://x.io here"), .prose)
    }

    func testDecorationLineIsProse() {
        // Decoration stripping happens during reflow; classification is prose.
        XCTAssertEqual(classify("▶ note"), .prose)
        XCTAssertEqual(classify("● status"), .prose)
    }

    func testBlank() {
        XCTAssertEqual(classify(""), .blank)
        XCTAssertEqual(classify("    "), .blank)
        XCTAssertEqual(classify("\t"), .blank)
    }
}
