import CmuxNextSettings
import Testing

struct HighContrastLookSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let labs: [String: JSONValue] = value.map { ["highContrastLook": $0] } ?? [:]
        return CmuxConfigSnapshot.parse(.object(["labs": .object(labs)]), validDensities: [], validMetrics: [])
    }

    @Test func absentAndInvalidValuesStayOff() {
        #expect(!Self.parse(nil).highContrastLook)
        let invalid = Self.parse(.string("yes"))
        #expect(!invalid.highContrastLook)
        #expect(invalid.diagnostics.contains { $0.path == "labs.highContrastLook" })
    }

    @Test func toggleParsesBothDirections() {
        #expect(Self.parse(.bool(true)).highContrastLook)
        #expect(!Self.parse(.bool(false)).highContrastLook)
    }
}
