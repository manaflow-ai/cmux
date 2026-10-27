import CmuxNextDesignTokens
import CmuxNextSettings
import Testing

/// `markdown.font.size` (Settings > Appearance > Markdown Viewer > Default Font Size): the size
/// every markdown viewer opens at and Cmd-0 goes back to. 16 by default, 8 to 40, agent-settable
/// (looks only).
struct MarkdownFontSizeSettingTests {
    private static let path = ["markdown", "font", "size"]

    @Test func theRowDefaultsTo16AndReadsTheStoredSize() throws {
        let row = try #require(SettingsSchema.descriptor(for: Self.path))
        #expect(row.defaultValue == .number(16))
        #expect(row.effectiveValue(in: .object([:])) == .number(16))
        let root: JSONValue = .object(["markdown": .object(["font": .object(["size": .number(18)])])])
        #expect(row.effectiveValue(in: root) == .number(18))
        #expect(row.isCustomized(in: root))
    }

    @Test(arguments: [8.0, 12, 16, 40])
    func sizesInTheRangeAreAccepted(_ size: Double) throws {
        let row = try #require(SettingsSchema.descriptor(for: Self.path))
        #expect(row.accepts(.number(size)))
    }

    @Test(arguments: [7.0, 41, -1])
    func sizesOutsideTheRangeAreRefused(_ size: Double) throws {
        let row = try #require(SettingsSchema.descriptor(for: Self.path))
        #expect(!row.accepts(.number(size)))
        #expect(!row.accepts(.string("huge")))
    }

    @Test func anAgentMaySetIt() {
        #expect(SettingsSchema.agentSettableKeys.contains("markdown.font.size"))
    }
}
