import AppKit
import Foundation
import Testing
@testable import CmuxNextDesign

/// Figure drawings as a background (cx-t2x): six CC0 drawings from the National Gallery of Art,
/// bundled as grayscale files, listed first in the picker, drawn under a denser theme tint than a
/// painting, and the user's desktop picture as an opt-in source.
@MainActor
struct FigureDrawingBackdropTests {
    static let defaultID = "nga-degas-halevy-standing-66489"

    var drawings: [BackdropArt] { BackdropArt.allCases.filter { $0.rawValue.hasPrefix("nga-") } }

    @Test func sixCreditedCC0DrawingsShipInTheBundle() throws {
        #expect(drawings.count == 6)
        for art in drawings {
            #expect(art.attribution.hasSuffix("National Gallery of Art · CC0"), "\(art)")
            #expect(art.sourceURL.host == "www.nga.gov", "\(art)")
            let image = try #require(art.image(), "\(art) decodes")
            #expect(image.size.width >= 1_000)
            let size = try #require(try art.imageURL?.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            #expect(size < 300_000, "\(art) stays a small derivative")
        }
    }

    @Test func theBundledDrawingsAreGrayscaleSoTheThemeSetsTheirHue() throws {
        for art in drawings {
            let url = try #require(art.imageURL)
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.colorSpace?.model == .monochrome, "\(art)")
        }
    }

    @Test func thePickerListsTheDrawingsFirstThenTheDesktopPicture() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([0x01]).write(to: directory.appendingPathComponent("a-wallpaper.png"))
        let ids = BackdropCatalog(systemDirectory: directory, fileManager: .default, systemLimit: 1).choices.map(\.id)
        #expect(ids.prefix(6).allSatisfy { $0.hasPrefix("nga-") })
        #expect(ids.first == Self.defaultID)
        #expect(ids.count == BackdropArt.allCases.count + 2)
        #expect(ids[BackdropArt.allCases.count] == "desktop")
        #expect(ids.last?.hasPrefix("system:") == true)
    }

    /// A pale sheet under a dark theme keeps text readable: the drawing gets at least the
    /// drawing tint, a painting keeps the theme's own.
    @Test func aDrawingSitsUnderADenserTintThanAPainting() throws {
        let drawing = try #require(BackdropSelection(id: Self.defaultID))
        for fixture in [ThemeFixtures.catppuccinMocha, ThemeFixtures.githubLight] {
            let tokens = ThemeTokens.derive(from: fixture)
            let tint = WindowBackdrop(tokens, selection: drawing).tintOpacity
            #expect(tint >= 0.84)
            #expect(tint > tokens.wallpaperTintOpacity)
            #expect(WindowBackdrop(tokens, selection: .art(.wheatField)).tintOpacity == tokens.wallpaperTintOpacity)
        }
        // A lowered window opacity still wins: the user asked to see more of the art.
        var input = ThemeFixtures.catppuccinMocha
        input.backgroundOpacity = 0.5
        #expect(WindowBackdrop(ThemeTokens.derive(from: input), selection: drawing).tintOpacity == 0.5)
    }

    @Test func theDesktopPictureIsASelectableSource() throws {
        let desktop = try #require(BackdropSelection(id: "desktop"))
        #expect(desktop.id == "desktop")
        #expect(desktop.sourceURL == nil)
        #expect(!desktop.title.isEmpty)
        #expect(BackdropSelection(id: "desktop:") == nil)
    }
}
