import CmuxNextAppearance
@testable import CmuxNextSettings
import Testing

/// The palette's Background row lists the bundled art and Desktop Wallpaper. A background it does
/// not list (your own image, a macOS wallpaper) showed as its raw value in quotes, and a retired
/// painting id marked nothing current. The row now names what the window shows.
@Suite struct BackdropPaletteOptionTests {
    static var descriptor: SettingDescriptor {
        get throws { try #require(SettingsSchema.descriptor(for: BackdropSelectionSetting().configPath)) }
    }

    @Test func yourOwnImageShowsByName() throws {
        let options = try Self.descriptor.paletteOptions(current: .string("file:/Users/Shared/Harbor.png"), themeColors: [])
        let current = options.filter(\.isCurrent)
        #expect(current.map(\.title) == ["Harbor"])
        #expect(current.first?.value == .string("file:/Users/Shared/Harbor.png"))
    }

    @Test func aMacOSWallpaperShowsByName() throws {
        let path = "system:/System/Library/Desktop Pictures/Solid Colors/Blue.heic"
        let options = try Self.descriptor.paletteOptions(current: .string(path), themeColors: [])
        #expect(options.filter(\.isCurrent).map(\.title) == [try #require(BackdropSelection(id: path)).title])
    }

    /// A painting id from the earlier set chooses the work that replaced it, so that work is current.
    @Test func aRetiredPaintingMarksItsReplacement() throws {
        let replacement = try #require(BackdropSelection(id: "wheat-field-with-cypresses"))
        let options = try Self.descriptor.paletteOptions(current: .string("wheat-field-with-cypresses"), themeColors: [])
        #expect(options.filter(\.isCurrent).map(\.value) == [.string(replacement.id)])
    }

    @Test func aListedChoiceIsUnchanged() throws {
        let options = try Self.descriptor.paletteOptions(current: .string("none"), themeColors: [])
        #expect(options.filter(\.isCurrent).map(\.value) == [.string("none")])
        #expect(options.count == (try Self.descriptor.paletteOptions(current: nil, themeColors: [])).count)
    }
}
