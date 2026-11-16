@testable import CmuxNextControl
import Testing

/// The launch that ignores every customization layer, for a UI that is itself broken
/// (`open -a "cmux NIGHTLY" --args --no-customizations`, `CMUX_NO_CUSTOMIZATIONS=1`, or Option and
/// Shift held as it starts). Leo, 2026-11-14: "I want people to not accidentally soft lock themselves
/// and like have good recovery options or whatever".
@Suite struct LaunchIdentityNoCustomizationsTests {
    private let app = "/Applications/cmux NIGHTLY.app/Contents/MacOS/cmux NIGHTLY"

    @Test func theArgumentTheVariableOrHeldKeysIgnoreLayers() {
        #expect(LaunchIdentity.ignoresCustomizations(arguments: [app, "--no-customizations"], environment: [:]))
        #expect(LaunchIdentity.ignoresCustomizations(arguments: [app], environment: ["CMUX_NO_CUSTOMIZATIONS": "1"]))
        #expect(LaunchIdentity.ignoresCustomizations(arguments: [app], environment: ["CMUX_NO_CUSTOMIZATIONS": "yes"]))
        #expect(LaunchIdentity.ignoresCustomizations(arguments: [app], environment: [:], keysHeld: true))
    }

    @Test func aPlainLaunchServesLayers() {
        #expect(!LaunchIdentity.ignoresCustomizations(arguments: [app], environment: [:]))
        for off in ["", "0", "false", "No"] {
            #expect(!LaunchIdentity.ignoresCustomizations(arguments: [app], environment: ["CMUX_NO_CUSTOMIZATIONS": off]))
        }
        // The executable's own path is not an argument.
        #expect(!LaunchIdentity.ignoresCustomizations(arguments: ["--no-customizations"], environment: [:]))
    }

    /// `open --env CMUX_NO_CUSTOMIZATIONS=1` or a shell launch keeps it through the launch strip; one
    /// another cmux's terminal passed on is that cmux's, and goes.
    @Test func theVariableSurvivesTheStripUnlessAnotherCmuxSetIt() {
        let own = ["CMUX_NO_CUSTOMIZATIONS": "1"]
        #expect(LaunchIdentity.inheritedKeys(processEnvironment: own, bundledEnvironment: [:]).isEmpty)
        let foreign = ["CMUX_NO_CUSTOMIZATIONS": "1", "CMUX_BUNDLE_ID": "com.cmuxterm.app.nightly"]
        #expect(Set(LaunchIdentity.inheritedKeys(processEnvironment: foreign, bundledEnvironment: [:])).contains("CMUX_NO_CUSTOMIZATIONS"))
    }
}
