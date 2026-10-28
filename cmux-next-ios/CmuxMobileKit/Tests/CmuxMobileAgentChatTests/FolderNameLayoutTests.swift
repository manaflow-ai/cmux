import CmuxMobileDiff
import CoreGraphics
import Testing

/// Round 4 review N8: the folder beside a file name never shows as a sliver.
@Suite struct FolderNameLayoutTests {
    @Test func theFolderGetsWhatTheNameLeaves() {
        let w = FolderNameLayout.widths(folderIdeal: 200, nameIdeal: 150, available: 260, minimumFolder: 36, spacing: 0)
        #expect(w.name == 150 && w.folder == 110)
    }

    @Test func aFolderUnderThreeCharactersIsLeftOut() {
        let w = FolderNameLayout.widths(folderIdeal: 200, nameIdeal: 230, available: 260, minimumFolder: 36, spacing: 0)
        #expect(w.folder == 0 && w.name == 230)
        let tight = FolderNameLayout.widths(folderIdeal: 200, nameIdeal: 300, available: 260, minimumFolder: 36, spacing: 10)
        #expect(tight.folder == 0 && tight.name == 260)
    }

    @Test func aFolderThatFitsIsWhole() {
        let w = FolderNameLayout.widths(folderIdeal: 80, nameIdeal: 150, available: 400, minimumFolder: 36, spacing: 10)
        #expect(w.folder == 80 && w.name == 150)
    }
}
