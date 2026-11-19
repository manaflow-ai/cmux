import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// The taste experiments in Settings > Advanced > Labs: `experiments.elevationLadder`,
/// `experiments.focusDimming` and its amount `experiments.focusDimAmount`. Both are off by default,
/// so a default app keeps its look; the amount stays in 0...1, and a bad value keeps the default and
/// says why.
struct TasteExperimentsSettingTests {
    static func parse(_ experiments: [String: JSONValue]?) -> CmuxConfigSnapshot {
        var root: [String: JSONValue] = [:]
        if let experiments { root["experiments"] = .object(experiments) }
        return CmuxConfigSnapshot.parse(.object(root), validDensities: [], validMetrics: [])
    }

    @Test func offByDefaultSoTheDefaultLookStays() {
        let snapshot = Self.parse(nil)
        #expect(!snapshot.elevationLadder)
        #expect(!snapshot.focusDimming)
        #expect(snapshot.focusDimAmount == 0.35)
        #expect(snapshot.diagnostics.isEmpty, "no key, no diagnostic: \(snapshot.diagnostics)")
    }

    @Test func eachSwitchTurnsOn() {
        let snapshot = Self.parse(["elevationLadder": .bool(true), "focusDimming": .bool(true), "focusDimAmount": .number(0.6)])
        #expect(snapshot.elevationLadder)
        #expect(snapshot.focusDimming)
        #expect(snapshot.focusDimAmount == 0.6)
        #expect(snapshot.diagnostics.isEmpty, "\(snapshot.diagnostics)")
    }

    @Test(arguments: [(-1.0, 0.0), (2.0, 1.0)])
    func theAmountIsClampedIntoItsRange(_ value: Double, _ expected: Double) {
        #expect(Self.parse(["focusDimAmount": .number(value)]).focusDimAmount == expected)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(["elevationLadder": .string("yes"), "focusDimAmount": .string("half")])
        #expect(!snapshot.elevationLadder)
        #expect(snapshot.focusDimAmount == 0.35)
        #expect(snapshot.diagnostics.contains { $0.path == "experiments.elevationLadder" }, "\(snapshot.diagnostics)")
        #expect(snapshot.diagnostics.contains { $0.path == "experiments.focusDimAmount" }, "\(snapshot.diagnostics)")
    }

    /// The design settings ask for a dim only while the switch is on: the amount alone changes nothing.
    @MainActor @Test func theDimIsTheAmountOnlyWhileOn() {
        let design = DesignSettings()
        design.focusDimAmount = 0.5
        #expect(design.focusDim == 0)
        design.focusDimming = true
        #expect(design.focusDim == 0.5)
    }
}
