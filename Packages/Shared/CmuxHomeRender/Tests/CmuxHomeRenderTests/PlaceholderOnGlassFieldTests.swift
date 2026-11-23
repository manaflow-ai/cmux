import CoreGraphics
import Testing
@testable import CmuxHomeRender

/// The Chief composer's placeholder over an opaque window. The palette raised it to 4.5:1 on the
/// field's fill (`composeGlass`), but the field is system glass, which draws that fill a step toward
/// mid grey: white came out 247 and the dark field 60 on the default themes, and the placeholder read
/// 4.22:1 (light) and 4.43:1 (dark) (fleet capture of b409aec1, text-inputs-glass/states.py,
/// chief-plain). It reads at 4.5:1 on the fill and on the fill drawn 10 % toward mid grey.
@Suite struct PlaceholderOnGlassFieldTests {
    nonisolated static let themes: [HomePalette.Theme] = [
        .init(background: .gray255(255), foreground: .gray255(29), accent: .rgb255(2, 132, 254), failure: .rgb255(215, 0, 21)),
        .init(background: .gray255(30), foreground: .gray255(230), accent: .rgb255(2, 132, 254), failure: .rgb255(255, 69, 58)),
        .init(background: .gray255(246), foreground: .gray255(36), accent: .rgb255(2, 132, 254), failure: .rgb255(215, 0, 21)),
        .init(background: .gray255(22), foreground: .gray255(238), accent: .rgb255(2, 132, 254), failure: .rgb255(255, 69, 58)),
    ]

    @Test(arguments: themes)
    func placeholderReadsOnTheGlassDrawnField(_ theme: HomePalette.Theme) {
        let palette = HomePalette.themed(theme)
        let field = palette.composeGlass.with(alpha: 1)
        for drawn in [field, field.mixed(with: .gray255(128), 0.1)] {
            #expect(palette.placeholder.contrast(with: drawn) >= HomePalette.minimumTextContrast - 0.005,
                    "placeholder \(palette.placeholder.contrast(with: drawn)):1 on \(drawn)")
        }
    }
}
