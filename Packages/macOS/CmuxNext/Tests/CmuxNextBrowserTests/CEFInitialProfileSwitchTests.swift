import Foundation
import Testing
@testable import CmuxNextBrowser

/// hq#7860: Chrome style opened its own `Default` profile at launch, beside the default cmux
/// profile, and each regular profile ran its own built-in uBlock Origin background page (an
/// extension renderer of about 105 MB). Chromium now starts in the default cmux profile.
@Suite struct CEFInitialProfileSwitchTests {
    @Test func chromiumStartsInTheDefaultCmuxProfile() {
        let storage = CEFProfileStorage(root: URL(filePath: "/tmp/cmux-test/Chromium"))
        #expect(storage.initialProfileDirectory == storage.cachePath(for: .default).lastPathComponent)
        #expect(storage.initialProfileDirectory == "Profile-8E5C0D1F-2B7A-4F3C-9A61-5D2E7B0C4A11")
        let switches = CEFSwitches.current(forkAPIVersion: 7, bundleIdentifier: "com.cmuxterm.app.next", environment: [:],
                                           initialProfileDirectory: storage.initialProfileDirectory)
        #expect(switches.arguments.contains("profile-directory=Profile-8E5C0D1F-2B7A-4F3C-9A61-5D2E7B0C4A11"))
    }

    @Test func noDirectoryLeavesChromiumItsOwnChoice() {
        let switches = CEFSwitches.current(forkAPIVersion: 7, bundleIdentifier: "com.cmuxterm.app.next", environment: [:])
        #expect(!switches.arguments.contains { $0.hasPrefix("profile-directory=") })
    }
}
