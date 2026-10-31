import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `sidebar.textSize` (Lawrence msg 17752: "we also need option for sidebar text to be very
/// significantly bigger ... let's match them [ChatGPT]"), then "default is ChatGPT size. the one that is
/// current is small.. small | medium | large": Medium by default, Small and Large by choice, the first
/// setting's "default" and "larger" read as Medium; a bad value keeps the default and says why. Every surface reads the schema
/// row, so the row's presence and agent policy are what put it in Settings, Cmd-Shift-P, the CLI
/// and MCP.
struct SidebarTextSizeSettingTests {
    private static let path = ["sidebar", "textSize"]

    private func snapshot(_ size: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = size.map { .object(["sidebar": .object(["textSize": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func absentIsMedium() {
        #expect(snapshot(nil).sidebarSections.textSize == .medium)
    }

    @Test(arguments: [("small", SidebarTextSize.small), ("medium", .medium), ("large", .large), ("default", .medium), ("larger", .medium)])
    func eachChoiceIsRead(raw: String, size: SidebarTextSize) {
        let parsed = snapshot(.string(raw))
        #expect(parsed.sidebarSections.textSize == size)
        #expect(!parsed.diagnostics.contains { $0.path == "sidebar.textSize" })
    }

    @Test func aBadValueKeepsTheDefaultWithADiagnostic() {
        let parsed = snapshot("huge")
        #expect(parsed.sidebarSections.textSize == .medium)
        #expect(parsed.diagnostics.contains { $0.path == "sidebar.textSize" })
    }

    @Test func theSchemaListsItForEverySurface() throws {
        let row = try #require(SettingsSchema.descriptor(for: Self.path))
        #expect(row.defaultValue == .string("medium"))
        guard case let .choice(choices) = row.kind else {
            Issue.record("sidebar.textSize is not a choice")
            return
        }
        #expect(choices.map(\.value) == ["small", "medium", "large"])
        #expect(row.isPaletteExposed)
        #expect(SettingsSchema.agentSettableKeys.contains("sidebar.textSize"))
    }
}
