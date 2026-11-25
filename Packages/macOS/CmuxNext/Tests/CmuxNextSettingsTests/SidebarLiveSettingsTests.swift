import CmuxNextSettings
import Testing

/// `presence.live` and `sidebar.showLiveToggle` (RFD 0141 phase 1; Leo 2026-11-24: an icon "somewhere omnipresent...
/// say the bottom left of the sidebar area"): Live is opt-in so it is off by default, the button shows by default,
/// and a bad value keeps the default with a diagnostic.
struct SidebarLiveSettingsTests {
    static func parse(_ root: JSONValue) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func liveIsOffAndTheButtonShowsByDefault() {
        let snapshot = Self.parse(.object([:]))
        #expect(snapshot.sidebarSections.presenceLive == false)
        #expect(snapshot.sidebarSections.showLiveToggle)
        #expect(snapshot.diagnostics.isEmpty, "\(snapshot.diagnostics)")
    }

    @Test func theUserCanTurnLiveOnAndHideTheButton() {
        let snapshot = Self.parse(.object(["presence": .object(["live": .bool(true)]),
                                           "sidebar": .object(["showLiveToggle": .bool(false)])]))
        #expect(snapshot.sidebarSections.presenceLive)
        #expect(snapshot.sidebarSections.showLiveToggle == false)
    }

    @Test func aBadValueKeepsTheDefaultWithADiagnostic() {
        let snapshot = Self.parse(.object(["presence": .object(["live": .string("yes")])]))
        #expect(snapshot.sidebarSections.presenceLive == false)
        #expect(snapshot.diagnostics.contains { $0.path == "presence.live" }, "\(snapshot.diagnostics)")
    }

    @Test func theSchemaListsBoth() throws {
        #expect(try #require(SettingsSchema.descriptor(for: ["presence", "live"])).defaultValue == .bool(false))
        #expect(try #require(SettingsSchema.descriptor(for: ["sidebar", "showLiveToggle"])).defaultValue == .bool(true))
    }
}
