import CmuxNextSettings
import Testing

/// `tabs.terminalFirst` (#23021): off by default, so Cmd-T keeps opening the New Tab page; Settings
/// lists the toggle, and a bad value keeps the default with a diagnostic.
struct TerminalFirstSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["tabs": .object(["terminalFirst": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func offByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.terminalFirst == false)
        #expect(snapshot.diagnostics.isEmpty, "no key, no diagnostic: \(snapshot.diagnostics)")
    }

    @Test func theUserCanTurnItOn() {
        #expect(Self.parse(.bool(true)).terminalFirst)
        #expect(Self.parse(.bool(false)).terminalFirst == false)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(.string("yes"))
        #expect(snapshot.terminalFirst == false)
        #expect(snapshot.diagnostics.contains { $0.path == "tabs.terminalFirst" }, "\(snapshot.diagnostics)")
    }

    @Test func settingsListsTheToggleOffInGeneralTabs() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["tabs", "terminalFirst"]))
        #expect(descriptor.defaultValue == .bool(false))
        #expect(descriptor.section == .general)
    }
}
