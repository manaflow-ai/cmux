import CmuxNextSettings
import Testing

/// `app.backgroundReady` (Leo 2026-11-17, ask-b2b0f899c1: "how can we improve those? startup in background
/// maybe?"): off by default, the four values read as written, anything else reads as off and says why, and
/// the row is a choice in Settings > General beside the Dock icon row.
struct BackgroundReadySettingTests {
    private static func root(_ value: JSONValue?) -> JSONValue {
        .object(["app": .object(value.map { ["backgroundReady": $0] } ?? [:])])
    }

    private static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(root(value), validDensities: [], validMetrics: [])
    }

    @Test func offByDefault() {
        #expect(BackgroundReadySetting.value(in: Self.root(nil)) == "off")
        #expect(BackgroundReadySetting.fallback == "off")
        #expect(Self.parse(nil).diagnostics.isEmpty)
    }

    @Test(arguments: ["off", "warmAtLogin", "afterQuit", "afterQuitAndLogin"])
    func eachValueReadsAsWritten(_ value: String) {
        #expect(BackgroundReadySetting.value(in: Self.root(.string(value))) == value)
        #expect(Self.parse(.string(value)).diagnostics.isEmpty)
    }

    @Test(arguments: [JSONValue.string("always"), .bool(true), .number(1)])
    func aBadValueReadsAsOffAndSaysWhy(_ value: JSONValue) {
        #expect(BackgroundReadySetting.value(in: Self.root(value)) == "off")
        #expect(Self.parse(value).diagnostics.map(\.path) == ["app.backgroundReady"])
    }

    @Test func rowIsAChoiceInGeneralNextToTheDockIconRow() throws {
        let row = try #require(SettingsSchema.descriptor(for: BackgroundReadySetting.configPath))
        #expect(row.section == .general)
        #expect(row.defaultValue == .string("off"))
        #expect(row.title == "Stay Ready in the Background")
        guard case .choice(let choices) = row.kind else { Issue.record("not a choice: \(row.kind)"); return }
        #expect(choices.map(\.value) == ["off", "warmAtLogin", "afterQuit", "afterQuitAndLogin"])
        let general = SettingsSchema.all.filter { $0.section == .general }.map(\.path)
        let dock = try #require(general.firstIndex(of: CmuxConfigSnapshot.hideDockIconWithoutWindowsPath))
        #expect(general.indices.contains(dock + 1) && general[dock + 1] == BackgroundReadySetting.configPath)
    }
}
