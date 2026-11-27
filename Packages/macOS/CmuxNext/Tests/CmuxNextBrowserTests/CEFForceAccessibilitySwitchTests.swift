import Testing
@testable import CmuxNextBrowser

@Suite struct CEFForceAccessibilitySwitchTests {
    @Test(arguments: [
        (["CMUX_NEXT_ACCESSIBILITY": "1"], true),
        (["CMUX_NEXT_ACCESSIBILITY": "0"], false),
        ([:], false),
    ])
    func launchEnvironmentForcesPageAccessibility(environment: [String: String], expected: Bool) {
        let switches = CEFSwitches.current(forkAPIVersion: 0, bundleIdentifier: "com.cmuxterm.app.nightly",
                                           environment: environment)
        #expect(switches.forcesRendererAccessibility == expected)
        #expect(switches.arguments.contains("force-renderer-accessibility") == expected)
    }
}
