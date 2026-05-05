import XCTest
@testable import CMUXPasteboardFidelity

final class PasteboardTextFidelityTests: XCTestCase {
    func testPrefersPlainTextWhenRichTextUsesQuestionMarkSubstitution() {
        XCTAssertTrue(
            PasteboardTextFidelity.shouldPreferPlainText(
                "한글 테스트 paste",
                overRichText: "?? ?? paste"
            )
        )
    }

    func testPrefersPlainTextWhenRichTextUsesReplacementCharacters() {
        XCTAssertTrue(
            PasteboardTextFidelity.shouldPreferPlainText(
                "한글 paste",
                overRichText: "\u{FFFD}\u{FFFD} paste"
            )
        )
    }

    func testPrefersPlainTextWhenRichTextExpandsOneScalarIntoMultipleReplacementCharacters() {
        XCTAssertTrue(
            PasteboardTextFidelity.shouldPreferPlainText(
                "한",
                overRichText: "\u{FFFD}\u{FFFD}\u{FFFD}"
            )
        )
    }

    func testPrefersPlainTextWhenRichTextDropsNonASCIICharacters() {
        XCTAssertTrue(
            PasteboardTextFidelity.shouldPreferPlainText(
                "한글 paste",
                overRichText: " paste"
            )
        )
    }

    func testKeepsRichTextWhenItPreservesNonASCIIPlainTextDropped() {
        XCTAssertFalse(
            PasteboardTextFidelity.shouldPreferPlainText(
                "test",
                overRichText: "test? 한글"
            )
        )
    }

    func testKeepsRichTextWhenQuestionMarkIsLegitimateASCIIContent() {
        XCTAssertFalse(
            PasteboardTextFidelity.shouldPreferPlainText(
                "test",
                overRichText: "test?"
            )
        )
    }

    func testHTMLWithOnlyHiddenBlocksHasNoVisibleText() {
        let html = """
        <!-- comment -->
        <style>
        body { content: "visible only to CSS"; }
        </style>
        <SCRIPT>
        document.body.innerText = "visible only to JS"
        </SCRIPT>
        <template>hidden template text</template>
        <noscript>fallback markup</noscript>
        &nbsp;&#160;&#xA0;
        """

        XCTAssertTrue(PasteboardTextFidelity.htmlHasNoVisibleText(html))
    }

    func testHTMLWithVisibleTextAfterHiddenBlocksHasVisibleText() {
        let html = """
        <style>
        p::before { content: "not visible paste text"; }
        </style>
        <p>한글 paste</p>
        """

        XCTAssertFalse(PasteboardTextFidelity.htmlHasNoVisibleText(html))
    }
}
