import XCTest
@testable import CmuxTerminal

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

    func testInspectsRichTextWhenPlainTextHasLossyMarkers() {
        XCTAssertTrue(PasteboardTextFidelity.shouldInspectRichTextForPlainTextLoss("??~"))
        XCTAssertTrue(PasteboardTextFidelity.shouldInspectRichTextForPlainTextLoss("\u{FFFD}~"))
        XCTAssertFalse(PasteboardTextFidelity.shouldInspectRichTextForPlainTextLoss("您好~"))
        XCTAssertFalse(PasteboardTextFidelity.shouldInspectRichTextForPlainTextLoss("Is this right?"))
        XCTAssertTrue(PasteboardTextFidelity.shouldInspectRichTextForPlainTextLoss("?????? ???"))
        XCTAssertTrue(PasteboardTextFidelity.shouldInspectRichTextForPlainTextLoss("name: ??? (id 4)"))
    }

    // #9998: isolated question marks are ordinary ASCII content, so they must
    // not send the paste through rich-text parsing.
    func testDoesNotInspectRichTextForIsolatedQuestionMarks() {
        XCTAssertFalse(PasteboardTextFidelity.shouldInspectRichTextForPlainTextLoss("Is this right? Or that?"))
        XCTAssertFalse(
            PasteboardTextFidelity.shouldInspectRichTextForPlainTextLoss(
                "See https://a.test/x?id=1 and https://b.test/y?q=2&r=3"
            )
        )
        XCTAssertFalse(
            PasteboardTextFidelity.shouldInspectRichTextForPlainTextLoss(
                "echo ${1:?missing}; [ -z \"$x\" ] && echo why?\n" + String(repeating: "Why? ", count: 1_000)
            )
        )
    }

    func testPrefersRichTextWhenPlainTextReplacesNonASCIIWithQuestionMarks() {
        XCTAssertTrue(
            PasteboardTextFidelity.shouldPreferRichText(
                "您好~",
                overPlainText: "??~"
            )
        )
    }

    func testDoesNotPreferRichTextWhenQuestionMarkIsPreservedContent() {
        XCTAssertFalse(
            PasteboardTextFidelity.shouldPreferRichText(
                "what? 您好",
                overPlainText: "what?"
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
