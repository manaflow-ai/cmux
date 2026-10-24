import AppKit
@testable import CmuxNextPalette
import Testing

/// The faces a font setting's rows draw their titles in belong to the result list that makes the
/// rows (``PaletteListView``), not to the process: each owner keeps the font it made, so a redraw
/// as the highlight moves reuses it (a font made and dropped at once can come back null).
@MainActor
struct PaletteFontFacesTests {
    @Test func anOwnerKeepsTheFaceItMade() throws {
        let faces = PaletteFontFaces()
        let menlo = try #require(faces.font(family: "Menlo", size: 13), "Menlo is installed on every macOS")
        #expect(menlo.familyName == "Menlo")
        #expect(faces.font(family: "Menlo", size: 13) === menlo, "the face was made again")
        #expect(faces.font(family: "Menlo", size: 15)?.pointSize == 15, "a size kept the other size's face")
    }

    @Test func aFamilyThatIsNotInstalledHasNoFace() {
        let faces = PaletteFontFaces()
        #expect(faces.font(family: "cmux-not-an-installed-family", size: 13) == nil)
        #expect(faces.font(family: "cmux-not-an-installed-family", size: 13) == nil)
    }
}
