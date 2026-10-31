import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `sidebar.textSize` (Lawrence msg 17752: "we also need option for sidebar text to be very
/// significantly bigger ... let's match them [ChatGPT]"): the original size by default, Large and
/// Larger by choice; a bad value keeps the default and says why. Every surface reads the schema
/// row, so the row's presence and agent policy are what put it in Settings, Cmd-Shift-P, the CLI
/// and MCP.
struct SidebarTextSizeSettingTests {
    private static let path = ["sidebar", "textSize"]

    private func snapshot(_ size: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = size.map { .object(["sidebar": .object(["textSize": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func absentIsTheOriginalSize() {
        #expect(snapshot(nil).sidebarSections.textSize == .standard)
    }

    @Test(arguments: [("large", SidebarTextSize.large), ("larger", .larger), ("default", .standard)])
    func eachChoiceIsRead(raw: String, size: SidebarTextSize) {
        let parsed = snapshot(.string(raw))
        #expect(parsed.sidebarSections.textSize == size)
        #expect(!parsed.diagnostics.contains { $0.path == "sidebar.textSize" })
    }

    @Test func aBadValueKeepsTheDefaultWithADiagnostic() {
        let parsed = snapshot("huge")
        #expect(parsed.sidebarSections.textSize == .standard)
        #expect(parsed.diagnostics.contains { $0.path == "sidebar.textSize" })
    }

    @Test func theSchemaListsItForEverySurface() throws {
        let row = try #require(SettingsSchema.descriptor(for: Self.path))
        #expect(row.defaultValue == .string("default"))
        guard case let .choice(choices) = row.kind else {
            Issue.record("sidebar.textSize is not a choice")
            return
        }
        #expect(choices.map(\.value) == ["default", "large", "larger"])
        #expect(row.isPaletteExposed)
        #expect(SettingsSchema.agentSettableKeys.contains("sidebar.textSize"))
    }
}
