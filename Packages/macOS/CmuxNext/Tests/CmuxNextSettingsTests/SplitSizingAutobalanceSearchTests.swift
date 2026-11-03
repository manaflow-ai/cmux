import CmuxNextSettings
import Testing

/// `layout.splitSizing` (Settings > General > Columns > Split Sizing) is the autobalance option:
/// `even` gives every pane in the column the same size after a split, and `halve` only halves the
/// pane that was split. Users look for it by the word "autobalance", so the words the palette and
/// Settings search (`SettingsPaletteSource`: keywords, id, section, group) must find this row.
struct SplitSizingAutobalanceSearchTests {
    private static func searchWords(_ descriptor: SettingDescriptor) -> [String] {
        descriptor.keywords + [descriptor.id, descriptor.section.title, descriptor.group]
    }

    private static func matches(_ query: String, _ descriptor: SettingDescriptor) -> Bool {
        let needle = query.lowercased()
        return searchWords(descriptor).contains { $0.lowercased().contains(needle) }
    }

    @Test func autobalanceFindsTheSplitSizingRow() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["layout", "splitSizing"]))
        #expect(Self.matches("autobalance", descriptor), "search words: \(Self.searchWords(descriptor))")
    }

    @Test func evenIsTheDefaultAutobalance() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["layout", "splitSizing"]))
        #expect(descriptor.defaultValue == .string("even"))
    }
}
