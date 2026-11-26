import CmuxNextDesign
import CmuxNextSettings
import Testing

struct LiveTreeSettingTests {
    private func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["labs": .object(["liveTree": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func defaultOffAndReversible() throws {
        #expect(!parse(nil).liveTree)
        #expect(parse(.bool(true)).liveTree)
        #expect(!parse(.bool(false)).liveTree)
        #expect(!parse(.string("yes")).liveTree)
        let descriptor = try #require(SettingsSchema.descriptor(for: ["labs", "liveTree"]))
        #expect(descriptor.defaultValue == .bool(false))
        #expect(descriptor.isPaletteExposed)
        #expect(SettingsSchema.agentRefusedKeys["labs.liveTree"] != nil)
    }
}
