import CmuxNextSettings
import Testing

/// `labs.hostsSidebar` keeps the Hosts projection opt-in until the person enables the Rex-style
/// sidebar surface. The parser and Settings row must agree on the same default and path.
struct HostsSidebarLabsSettingTests {
    @Test func offByDefault() throws {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.hostsSidebar == false)
        let row = try #require(SettingsSchema.descriptor(for: CmuxConfigSnapshot.hostsSidebarPath))
        #expect(row.defaultValue == .bool(false))
        #expect(row.kind == .toggle)
        #expect(SettingsSchema.agentSettable(row) == false)
    }

    @Test func cmuxJSONTurnsItOn() {
        let root: JSONValue = ["labs": ["hostsSidebar": true]]
        #expect(CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: []).hostsSidebar)
    }

    @Test func aValueThatIsNotABoolStaysOffWithADiagnostic() {
        let root: JSONValue = ["labs": ["hostsSidebar": "yes"]]
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.hostsSidebar == false)
        #expect(snapshot.diagnostics.contains { $0.path == "labs.hostsSidebar" })
    }
}
