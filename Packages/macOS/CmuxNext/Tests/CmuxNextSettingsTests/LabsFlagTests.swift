import CmuxNextSettings
import Testing

/// Labs (hq#1980): new looks and behaviors ship behind a `labs.<name>` flag that a person turns on,
/// not in the defaults. Each flag is a row in schemas/settings/source/labs.json with an owner, a
/// created date, an expiry, a cohort and a one-line intent; cmux.json turns it on or off, and with
/// nothing there the cohort decides (off, team builds, everyone).
struct LabsFlagTests {
    private func snapshot(_ labs: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(labs.isEmpty ? [:] : ["labs": .object(labs)]), validDensities: [], validMetrics: [])
    }

    @Test func aFlagIsOffWhenTheFileSaysNothing() {
        #expect(!snapshot([:]).lab(.previewFeatures, teamBuild: false))
        #expect(snapshot([:]).labsOn(teamBuild: false).isEmpty)
    }

    @Test func cmuxJSONTurnsAFlagOnAndOff() {
        let on = snapshot(["previewFeatures": .bool(true)])
        #expect(on.lab(.previewFeatures, teamBuild: false))
        #expect(on.previewFeatures)
        #expect(on.labsOn(teamBuild: false) == ["previewFeatures"])
        #expect(!snapshot(["previewFeatures": .bool(false)]).lab(.previewFeatures, teamBuild: true))
    }

    @Test func aValueThatIsNotOnOrOffIsOffWithADiagnostic() {
        let bad = snapshot(["previewFeatures": .string("yes")])
        #expect(!bad.lab(.previewFeatures, teamBuild: false))
        #expect(bad.diagnostics.contains { $0.path == "labs.previewFeatures" })
    }

    /// The cohort is the default: `nightly-next` flags are on in nightly and dev builds only, and a
    /// promoted (`default`) flag is on for everyone until the file says otherwise.
    @Test func theCohortDecidesWhenTheFileSaysNothing() {
        #expect(!LabsCohort.off.isOn(teamBuild: true))
        #expect(LabsCohort.nightlyNext.isOn(teamBuild: true))
        #expect(!LabsCohort.nightlyNext.isOn(teamBuild: false))
        #expect(LabsCohort.default.isOn(teamBuild: false))
        #expect(LabsFlag.isTeamBuild(bundleID: "com.cmuxterm.app.nightly.next"))
        #expect(LabsFlag.isTeamBuild(bundleID: "com.cmuxterm.app.debug.next"))
        #expect(!LabsFlag.isTeamBuild(bundleID: "com.cmuxterm.app.rc"))
        #expect(!LabsFlag.isTeamBuild(bundleID: "com.cmuxterm.app"))
        #expect(!LabsFlag.isTeamBuild(bundleID: "com.example.other"))
    }

    /// Every flag carries its registry fields, shows in Settings > Experimental > Labs as a toggle,
    /// and an agent may flip it like any other setting.
    @Test func everyFlagIsAToggleWithItsOwnerDatesAndIntent() {
        for flag in LabsFlag.allCases {
            #expect(flag.key == "labs." + flag.rawValue)
            #expect(!flag.owner.isEmpty && !flag.intent.isEmpty)
            #expect(flag.created < flag.expires, "\(flag.key): expires before it was created")
            let descriptor = SettingsSchema.descriptor(for: flag.path)
            #expect(descriptor?.kind == .toggle)
            #expect(descriptor?.defaultValue == .bool(flag.cohort == .default))
            #expect(SettingsSchema.agentSettableKeys.contains(flag.key))
        }
    }
}
