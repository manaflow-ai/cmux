import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `ui.animationSpeed`: "fast" unless the file says "normal" or "off"; a bad
/// value keeps "fast" and reports a diagnostic; removing the key restores it.
@Suite struct AnimationSpeedSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaultsToFast() throws {
        #expect(try parse("{}").animationSpeed == .fast)
        #expect(try parse(#"{"ui": {"surfaceTabBar": {}}}"#).animationSpeed == .fast)
        #expect(try parse("{}").diagnostics.isEmpty)
        #expect(CmuxConfigSnapshot.empty.animationSpeed == .fast)
    }

    @Test func readsEverySpeed() throws {
        for speed in MotionSpeed.allCases {
            #expect(try parse(#"{"ui": {"animationSpeed": "\#(speed.rawValue)"}}"#).animationSpeed == speed)
        }
    }

    @Test func badValuesKeepFastWithADiagnostic() throws {
        for text in [#"{"ui": {"animationSpeed": "slow"}}"#, #"{"ui": {"animationSpeed": 0}}"#] {
            let snapshot = try parse(text)
            #expect(snapshot.animationSpeed == .fast, "\(text)")
            #expect(snapshot.diagnostics.map(\.path) == ["ui.animationSpeed"], "\(text)")
        }
    }

    @MainActor @Test func appliesToDesignSettingsAndRevertsWhenRemoved() throws {
        let design = DesignSettings()
        let applier = SettingsApplier(design: design, registry: ActionRegistry.standard())
        applier.apply(try parse(#"{"ui": {"animationSpeed": "off"}}"#))
        #expect(design.animationSpeed == .off)
        applier.apply(try parse("{}"))
        #expect(design.animationSpeed == .fast)
    }
}
