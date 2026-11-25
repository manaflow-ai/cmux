import AppKit
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// Leo, 2026-10-20: readability over a background is not about the picture. It comes from how
/// much opacity, blur and glass the window lays over it, applied the same way whatever picture is
/// behind. No picture-dependent legibility floor raises the tint, no work brings its own tint, and
/// Frosted blurs the picture itself (the window's frost only reaches the desktop behind it).
@MainActor @Suite struct ReadabilityOverArtTests {
    static let tokens = ThemeTokens.derive(from: .ghosttyDefault)

    /// Bright and dark works, your own image and a macOS wallpaper.
    static var pictures: [BackdropSelection] {
        BackdropArt.allCases.map(BackdropSelection.art)
            + [.file(path: "/Users/Shared/Harbor.png"), .system(path: "/System/Library/Desktop Pictures/Solid Colors/Blue.heic")]
    }

    static func tokens(blur: Int) -> ThemeTokens {
        var input = ThemeInput.ghosttyDefault
        input.backgroundBlur = blur
        return ThemeTokens.derive(from: input)
    }

    /// The Opacity the person sets is the tint over every picture, low values included (the floor
    /// made the lower range of the slider dead, #22378).
    @Test func theOpacityAskedForIsTheTintOverAnyPicture() {
        for picture in Self.pictures {
            for opacity in [0.0, 0.1, 0.3, 0.6, 0.9] {
                let backdrop = WindowBackdrop(Self.tokens, selection: picture, tintOpacity: opacity)
                #expect(abs(backdrop.tintOpacity - opacity) < 0.0001, "\(picture.id) at \(opacity) shows \(backdrop.tintOpacity)")
            }
        }
    }

    /// Unset, every picture gets the same tint: the theme's, never one the work brings.
    @Test func everyPictureGetsTheSameTintWhenUnset() {
        let tints = Set(Self.pictures.map { WindowBackdrop(Self.tokens, selection: $0).tintOpacity })
        #expect(tints == [Self.tokens.wallpaperTintOpacity])
    }

    /// Frosted over a picture blurs the picture by the material's radius; other materials leave it sharp.
    @Test func frostedBlursThePicture() {
        let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 400, height: 300),
                                      images: BackdropImageStore(maxPixelSize: 64), videos: BackdropVideoPlayers())
        let work = BackdropSelection.art(.vanGoghStarryNight)
        view.apply(WindowBackdrop(Self.tokens(blur: 20), selection: work), tint: .black)
        let blur = (view.artView.layer?.filters as? [CIFilter])?.first { $0.name == "CIGaussianBlur" }
        #expect((blur?.value(forKey: kCIInputRadiusKey) as? NSNumber)?.doubleValue == 20)
        // The video over the art blurs the same way.
        #expect((view.videoView.layer?.filters as? [CIFilter])?.contains { $0.name == "CIGaussianBlur" } == true)
        view.apply(WindowBackdrop(Self.tokens(blur: 0), selection: work), tint: .black)
        #expect((view.artView.layer?.filters ?? []).isEmpty)
    }
}
