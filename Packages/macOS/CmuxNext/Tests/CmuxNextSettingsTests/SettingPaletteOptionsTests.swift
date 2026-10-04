import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// The palette's value lists, built from the schema for every kind
/// (R93 generic mechanism, R98 swatches).
@Suite struct SettingPaletteOptionsTests {
    private func descriptor(_ key: String) throws -> SettingDescriptor {
        try #require(SettingsSchema.descriptor(for: key.split(separator: ".").map(String.init)))
    }

    @Test func aChoiceListsItsValuesAndMarksTheCurrentOne() throws {
        let options = try descriptor("layout.paneSeparation").paletteOptions(current: "none", themeColors: [])
        #expect(options.map(\.value) == ["none", "dividers", "borders", "cards"])
        #expect(options.filter(\.isCurrent).map(\.value) == ["none"])
        #expect(options.allSatisfy { $0.swatches.isEmpty })
    }

    @Test func aToggleListsOnAndOff() throws {
        let options = try descriptor("sidebar.border").paletteOptions(current: .bool(true), themeColors: [])
        #expect(options.map(\.value) == [.bool(true), .bool(false)])
        #expect(options.first?.isCurrent == true)
    }

    /// A number is a stepper: the default first, then every step.
    @Test func aSmallNumberRangeListsEveryStep() throws {
        let options = try descriptor("layout.panePadding").paletteOptions(current: .number(4), themeColors: [])
        #expect(options.first?.value == nil, "the first row resets to the default")
        let values = options.dropFirst().compactMap { $0.value?.doubleValue }
        #expect(values == Array(stride(from: 0.0, through: 16, by: 1)))
        #expect(options.filter(\.isCurrent).map(\.value) == [.number(4)])
    }

    /// A wide range keeps the ends and the current value, on the step grid,
    /// at most 41 values.
    @Test func aWideNumberRangeIsSampledOnItsStepGrid() throws {
        let descriptor = try descriptor("notifications.timeoutSeconds")
        guard case .number(let number) = descriptor.kind else {
            Issue.record("expected a number")
            return
        }
        let options = descriptor.paletteOptions(current: .number(30), themeColors: [])
        let values = options.compactMap { $0.value?.doubleValue }
        #expect(values.count <= 41)
        #expect(values.first == number.range.lowerBound)
        #expect(values.last == number.range.upperBound)
        #expect(values.contains(30))
        #expect(values == values.sorted())
        for value in values where value != number.range.upperBound {
            let steps = (value - number.range.lowerBound) / number.step
            #expect(abs(steps - steps.rounded()) < 1e-9, "\(value) is off the step grid")
        }
    }

    /// A color shows its real color: the theme's colors as swatches, the
    /// theme default first, a custom current value kept.
    @Test func aColorListsSwatches() throws {
        let red = ThemeRGB(hex: 0xFF0000)
        let green = ThemeRGB(hex: 0x00FF00)
        let options = try descriptor("layout.paneBorderColor").paletteOptions(current: "#123456", themeColors: [red, green])
        #expect(options.first?.value == nil, "the first row is the theme's color")
        #expect(Array(options.map(\.value).dropFirst()) == ["#FF0000", "#00FF00", "#123456"])
        #expect(options[1].swatches == [red])
        #expect(options[2].swatches == [green])
        #expect(options[3].swatches == [ThemeRGB(hex: 0x123456)])
        #expect(options.filter(\.isCurrent).map(\.value) == ["#123456"])
    }
}

/// Live preview: the palette shows a value before it is written, and
/// leaving restores the file's value. Nothing is written until commit.
@MainActor @Suite struct SettingsPreviewTests {
    private func controller(_ text: String, managed: ManagedPreferences = ManagedPreferences()) throws -> (SettingsController, URL, DesignSettings) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux-next.json")
        try Data(text.utf8).write(to: url)
        let design = DesignSettings()
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: design, fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(managed), managedWatchFiles: [])
        return (settings, url, design)
    }

    @Test func previewAppliesWithoutWritingAndEndRestores() async throws {
        let (settings, url, design) = try controller("{}")
        await settings.reload()
        let descriptor = try #require(SettingsSchema.descriptor(for: ["layout", "paneSeparation"]))
        #expect(design.paneChrome.separation == nil)
        #expect(settings.preview(descriptor, "none"))
        #expect(design.paneChrome.separation == PaneSeparation.none)
        #expect(settings.previewingKey == "layout.paneSeparation")
        #expect(try String(contentsOf: url, encoding: .utf8) == "{}")
        #expect(settings.preview(descriptor, "cards"))
        #expect(design.paneChrome.separation == .cards)
        settings.endPreview()
        #expect(design.paneChrome.separation == nil)
        #expect(settings.previewingKey == nil)
    }

    @Test func aRefusedOrManagedValueDoesNotPreview() async throws {
        let speed = "ui.animationSpeed"
        let (settings, _, design) = try controller("{}", managed: ManagedPreferences(forced: [speed: "off"]))
        await settings.reload()
        #expect(design.animationSpeed == .off)
        let descriptor = try #require(SettingsSchema.descriptor(for: ["ui", "animationSpeed"]))
        #expect(!settings.preview(descriptor, "normal"))
        #expect(design.animationSpeed == .off)
        let separation = try #require(SettingsSchema.descriptor(for: ["layout", "paneSeparation"]))
        #expect(!settings.preview(separation, "lines"))
        #expect(settings.previewingKey == nil)
    }

    /// Committing writes the value; the reload ends the preview with the
    /// same look (no flash back to the old value).
    @Test func commitEndsThePreviewWithTheWrittenValue() async throws {
        let (settings, _, design) = try controller("{}")
        await settings.reload()
        let descriptor = try #require(SettingsSchema.descriptor(for: ["layout", "paneSeparation"]))
        settings.preview(descriptor, "dividers")
        try await settings.commitPreview(descriptor, "dividers")
        #expect(settings.previewingKey == nil)
        #expect(design.paneChrome.separation == .dividers)
        await settings.reload()
        #expect(design.paneChrome.separation == .dividers)
        #expect(settings.fileRoot.value(at: ["layout", "paneSeparation"]) == "dividers")
    }
}
