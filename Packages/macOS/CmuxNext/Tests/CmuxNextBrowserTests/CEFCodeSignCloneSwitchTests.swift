import Foundation
import Testing
@testable import CmuxNextBrowser

/// Relaunch after a Chromium session (goal restart-to-chat): Chromium's MacAppCodeSignClone
/// hard-links the app's main executable into a per-launch clone in $TMPDIR/../X, and a
/// `--type=code-sign-clone-cleanup` helper removes it about 1 s after quit. The next launch of
/// that executable was held by macOS before its first instruction (`_dyld_start+0`, no CPU):
/// main_start 1447 ms against 26 ms with the feature off, 5 relaunch rounds each on one Mac.
@Suite struct CEFCodeSignCloneSwitchTests {
    @Test(arguments: ["com.cmuxterm.app.next", "com.cmuxterm.app.nightly", "com.cmuxterm.app.debug.tag"])
    func theAppTurnsOffChromiumsCodeSignClone(bundle: String) {
        let switches = CEFSwitches.current(forkAPIVersion: 30, bundleIdentifier: bundle, environment: [:])
        #expect(switches.arguments.contains("disable-features=MacAppCodeSignClone"))
    }
}
