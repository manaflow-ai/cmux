import CmuxNextDesignTokens
import CmuxNextSettings
import Testing

/// `appearance.machineColors`: a color per machine for its marks (sidebar rows, tab badges). Unset,
/// every machine keeps its automatic color; a bad entry is dropped with a diagnostic at its key.
struct MachineColorsSettingTests {
    private static func parse(_ colors: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = colors.map { .object(["appearance": .object(["machineColors": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func unsetPicksNothing() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.machineColors == .none)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func eachEntryLoadsUnderItsMachineKey() {
        let snapshot = Self.parse(.object(["Big-Red ": .string("#D0453A"), "build-mac": .string("cyan")]))
        #expect(snapshot.machineColors == MachineColorOverrides(["big-red": "#d0453a", "build-mac": "cyan"]))
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func aBadEntryIsDroppedAndSaysWhy() {
        let snapshot = Self.parse(.object(["big-red": .string("crimson"), "build-mac": .string("#12ab34"), "air-blue": .number(1)]))
        #expect(snapshot.machineColors == MachineColorOverrides(["build-mac": "#12ab34"]))
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.machineColors.big-red" })
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.machineColors.air-blue" })
    }

    @Test func aValueThatIsNoObjectPicksNothing() {
        let snapshot = Self.parse(.string("#12ab34"))
        #expect(snapshot.machineColors == .none)
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.machineColors" })
    }

    @Test func theRowIsAStringMapTheMachinesCardDraws() throws {
        let row = try #require(SettingsSchema.descriptor(for: ["appearance", "machineColors"]))
        #expect(row.kind == .stringMap)
        #expect(row.defaultValue == .object([:]))
        #expect(row.section == .machines)
        // Looks only: an agent may color a machine, as it may pick the accent.
        #expect(SettingsSchema.agentSettableKeys.contains(row.id))
        let accounts = try #require(SettingsPageLayout().categories().first { $0.spec.id == "accounts" })
        #expect(accounts.spec.lead.contains(.machines))
        #expect(accounts.groups.contains { $0.rows.contains(row.id) })
    }
}
