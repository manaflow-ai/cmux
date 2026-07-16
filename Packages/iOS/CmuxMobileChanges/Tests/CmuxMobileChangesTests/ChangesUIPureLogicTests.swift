import CmuxMobileChanges
import SwiftUI
import Testing

@Suite struct ChangesUIPureLogicTests {
    @Test @MainActor
    func themeResolvesDistinctLightAndDarkTokens() {
        let light = ChangesTheme(colorScheme: .light)
        let dark = ChangesTheme(colorScheme: .dark)

        #expect(light.additionBackground != dark.additionBackground)
        #expect(light.removalBackground != dark.removalBackground)
        #expect(light.hunkHeaderBackground != dark.hunkHeaderBackground)
    }

    @Test
    func gutterWidthUsesDigitCountAndMeasuredAdvance() {
        let layout = DiffGutterLayout(maximumLineNumber: 9_842)

        #expect(layout.digitCount == 4)
        #expect(layout.width(monospacedDigitAdvance: 7.5) == 34)
    }

    @Test
    func copyHunkAssemblesUnifiedPrefixes() {
        let hunk = DiffHunk(
            header: DiffLine(
                kind: .hunkHeader,
                text: "@@ -1,2 +1,2 @@",
                oldNumber: nil,
                newNumber: nil
            ),
            oldStart: 1,
            oldCount: 2,
            newStart: 1,
            newCount: 2,
            sectionContext: nil,
            lines: [
                DiffLine(kind: .context, text: "let stable = true", oldNumber: 1, newNumber: 1),
                DiffLine(kind: .removal, text: "let value = 1", oldNumber: 2, newNumber: nil),
                DiffLine(kind: .addition, text: "let value = 2", oldNumber: nil, newNumber: 2),
            ]
        )

        #expect(hunk.copyText == """
        @@ -1,2 +1,2 @@
         let stable = true
        -let value = 1
        +let value = 2
        """)
    }

    @Test
    func pagePositionClampsToAvailablePages() {
        #expect(DiffPagerPosition(selectedIndex: 2, pageCount: 7).currentPage == 3)
        #expect(DiffPagerPosition(selectedIndex: 99, pageCount: 7).currentPage == 7)
        #expect(DiffPagerPosition(selectedIndex: 0, pageCount: 0).currentPage == 0)
    }

    @Test(arguments: [
        (FileChangeKind.added, "plus.circle.fill"),
        (.untracked, "plus.circle"),
        (.modified, "pencil.circle.fill"),
        (.deleted, "minus.circle.fill"),
        (.renamed, "arrow.right.circle.fill"),
    ])
    func statusMapsToExpectedGlyph(kind: FileChangeKind, symbol: String) {
        #expect(kind.symbolName == symbol)
    }
}
