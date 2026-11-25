import Foundation
import Testing
@testable import CmuxNextBrowser

/// A long chat's renderer scavenged its young generation far more often than a short chat's while streaming
/// (CEFSwitches.youngGeneration), so renderers start with a 32 MB semi-space.
@Suite struct CEFYoungGenerationSwitchTests {
    @Test(arguments: ["com.cmuxterm.app.next", "com.cmuxterm.app.debug.tag"])
    func renderersStartWithALargerYoungGeneration(bundle: String) {
        let switches = CEFSwitches.current(forkAPIVersion: 7, bundleIdentifier: bundle, environment: [:])
        #expect(switches.arguments.contains("js-flags=--min-semi-space-size=32"))
    }
}
