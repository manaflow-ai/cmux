import CmuxNextDesign
@testable import CmuxNextSettings
import Testing

/// One `schema.rows` call answers what the per-row reads answer, so a Settings page or the palette
/// renders with one Rust round trip instead of about one per row and question.
@Suite struct SettingRowReadsTests {
    static let root: JSONValue = [
        "terminal": ["fontSize": 15, "cursorStyle": "nonsense"],
        "appearance": ["backdropArt": "wheat-field-with-cypresses"],
    ]
    static let file: JSONValue = ["terminal": ["fontSize": 15]]

    @Test func everyRowMatchesThePerRowReads() {
        let reads = SettingsSchema.reads(root: Self.root, storedRoot: Self.file)
        #expect(reads.count == SettingsSchema.all.count)
        for descriptor in SettingsSchema.all {
            let read = reads[descriptor.id]
            #expect(read?.stored == descriptor.storedValue(in: Self.file), Comment(rawValue: descriptor.id))
            #expect(read?.effective == descriptor.effectiveValue(in: Self.root), Comment(rawValue: descriptor.id))
            #expect(read?.customized == descriptor.isCustomized(in: Self.file), Comment(rawValue: descriptor.id))
            #expect(read?.toggled == descriptor.toggledValue(in: Self.root), Comment(rawValue: descriptor.id))
            #expect(read?.inherited == descriptor.inheritedValue(in: Self.root), Comment(rawValue: descriptor.id))
        }
    }

    @Test func thePaletteMatchesThePerRowOptions() {
        let colors = [ThemeRGB(red: 1, green: 0, blue: 0, alpha: 1)]
        let listed = SettingsSchema.all.filter { $0.isPaletteListed(developerTools: true) }
        let reads = SettingsSchema.reads(root: Self.root, keys: listed.map(\.id), palette: SettingPaletteReads(themeColors: colors))
        for descriptor in listed {
            guard let read = reads[descriptor.id] else {
                Issue.record("no read for \(descriptor.id)")
                continue
            }
            let single = descriptor.paletteOptions(current: read.effective, inherited: read.inherited, themeColors: colors)
            #expect(descriptor.paletteOptions(read, themeColors: colors) == single, Comment(rawValue: descriptor.id))
        }
    }

    /// The retired painting id is resolved by the app's catalog in the same call's second ask.
    @Test func aRetiredPaintingIsResolvedInTheBatch() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: BackdropSelectionSetting.configPath))
        let reads = SettingsSchema.reads(root: Self.root, keys: [descriptor.id])
        #expect(reads[descriptor.id]?.stored == descriptor.storedValue(in: Self.root))
        #expect(reads[descriptor.id]?.stored != nil)
    }
}
