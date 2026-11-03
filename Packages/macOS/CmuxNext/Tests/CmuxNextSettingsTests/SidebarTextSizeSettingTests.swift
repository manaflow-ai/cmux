import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// `sidebar.textSize` (Lawrence msg 17752: "we also need option for sidebar text to be very
/// significantly bigger ... let's match them [ChatGPT]"), then "small | medium | large", then (2026-11-02)
/// "the default for the sidebar text should be the codex text size": Small by default, Medium (ChatGPT) and
/// Large by choice; the first setting's "default" reads as Small and "larger" as Medium; a bad value keeps the
/// default and says why. The custom sizes (`sidebar.titleSize` and the rest) are absent by default. Every surface reads the schema
/// row, so the row's presence and agent policy are what put it in Settings, Cmd-Shift-P, the CLI
/// and MCP.
struct SidebarTextSizeSettingTests {
    private static let path = ["sidebar", "textSize"]

    private func snapshot(_ size: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = size.map { .object(["sidebar": .object(["textSize": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func absentIsSmall() {
        #expect(snapshot(nil).sidebarSections.textSize == .small)
    }

    @Test(arguments: [("small", SidebarTextSize.small), ("medium", .medium), ("large", .large), ("default", .small), ("larger", .medium)])
    func eachChoiceIsRead(raw: String, size: SidebarTextSize) {
        let parsed = snapshot(.string(raw))
        #expect(parsed.sidebarSections.textSize == size)
        #expect(!parsed.diagnostics.contains { $0.path == "sidebar.textSize" })
    }

    @Test func aBadValueKeepsTheDefaultWithADiagnostic() {
        let parsed = snapshot("huge")
        #expect(parsed.sidebarSections.textSize == .small)
        #expect(parsed.diagnostics.contains { $0.path == "sidebar.textSize" })
    }

    @Test func theSchemaListsItForEverySurface() throws {
        let row = try #require(SettingsSchema.descriptor(for: Self.path))
        #expect(row.defaultValue == .string("small"))
        guard case let .choice(choices) = row.kind else {
            Issue.record("sidebar.textSize is not a choice")
            return
        }
        #expect(choices.map(\.value) == ["small", "medium", "large"])
        #expect(row.isPaletteExposed)
        #expect(SettingsSchema.agentSettableKeys.contains("sidebar.textSize"))
    }

    // MARK: Custom sizes (2026-11-02: "make it so that i can custom the text sizes and the stuff as well")

    private static let customKeys = ["titleSize", "detailSize", "rowHeight", "rowPadding"]

    @Test func customSizesAreAbsentByDefault() {
        let parsed = snapshot(nil).sidebarSections
        #expect(parsed.titleSize == nil && parsed.detailSize == nil && parsed.rowHeight == nil && parsed.rowPadding == nil)
    }

    @Test func customSizesAreRead() {
        let root: JSONValue = .object(["sidebar": .object([
            "titleSize": .number(15), "detailSize": .number(11.5), "rowHeight": .number(34), "rowPadding": .number(12),
        ])])
        let parsed = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(parsed.sidebarSections.titleSize == 15 && parsed.sidebarSections.detailSize == 11.5)
        #expect(parsed.sidebarSections.rowHeight == 34 && parsed.sidebarSections.rowPadding == 12)
        #expect(!parsed.diagnostics.contains { $0.path.hasPrefix("sidebar.") })
    }

    @Test(arguments: customKeys)
    func anOutOfRangeCustomSizeIsIgnoredWithADiagnostic(key: String) {
        let root: JSONValue = .object(["sidebar": .object([key: .number(500)])])
        let parsed = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        let sections = parsed.sidebarSections
        #expect(sections.titleSize == nil && sections.detailSize == nil && sections.rowHeight == nil && sections.rowPadding == nil)
        #expect(parsed.diagnostics.contains { $0.path == "sidebar." + key })
    }

    @Test(arguments: customKeys)
    func eachCustomSizeIsOnEverySurface(key: String) throws {
        let row = try #require(SettingsSchema.descriptor(for: ["sidebar", key]))
        #expect(row.defaultValue == nil, "absent: the density's size")
        guard case .number = row.kind else {
            Issue.record("sidebar.\(key) is not a number")
            return
        }
        #expect(row.isPaletteExposed)
        #expect(SettingsSchema.agentSettableKeys.contains("sidebar." + key))
    }

    @Test func theDensityOffersNormalByDefault() throws {
        let row = try #require(SettingsSchema.descriptor(for: ["sidebar", "density"]))
        #expect(row.defaultValue == .string("normal"))
        guard case let .choice(choices) = row.kind else {
            Issue.record("sidebar.density is not a choice")
            return
        }
        #expect(choices.map(\.value) == ["compact", "normal", "comfortable", "expanded"])
        #expect(snapshot(nil).sidebarSections.density == .normal)
    }
}

/// The first setting's values ("default", "larger") are rewritten once at launch as the size they read as,
/// so Settings and the palette show the chosen size checked (review of issue 28793's port).
@MainActor @Suite(.serialized) struct SidebarTextSizeMigrationTests {
    private static func controller(_ json: String) throws -> (SettingsController, URL) {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-sidebar-text-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appending(path: "cmux-next.json")
        try Data(json.utf8).write(to: url)
        let settings = SettingsController(registry: .standard(), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        return (settings, home)
    }

    @Test(arguments: [("default", "small"), ("larger", "medium")])
    func theFirstSettingsValuesBecomeTheirSize(old: String, new: String) async throws {
        let (settings, home) = try Self.controller(#"{ "sidebar": { "textSize": "\#(old)" } }"#)
        defer { try? FileManager.default.removeItem(at: home) }
        await settings.reload()
        #expect(try await settings.migrateLegacySidebarTextSize())
        #expect(settings.snapshot.root.value(at: SidebarSectionsSetting.textSizePath) == .string(new))
        #expect(settings.snapshot.sidebarSections.textSize.rawValue == new)
        #expect(try await settings.migrateLegacySidebarTextSize() == false, "once")
    }

    @Test(arguments: ["small", "large", "nonsense"])
    func otherValuesAreLeft(value: String) async throws {
        let (settings, home) = try Self.controller(#"{ "sidebar": { "textSize": "\#(value)" } }"#)
        defer { try? FileManager.default.removeItem(at: home) }
        await settings.reload()
        #expect(try await settings.migrateLegacySidebarTextSize() == false)
        #expect(settings.snapshot.root.value(at: SidebarSectionsSetting.textSizePath) == .string(value))
    }
}
