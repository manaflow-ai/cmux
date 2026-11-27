import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextBrowser

/// Two Debug copies of one bundle id with their own tags keep their own Chromium profiles (cookies, logins): the
/// folder is the build key in a DEV build. Tagged DEV builds, NIGHTLY and release keep their bundle id's folder.
@Suite struct CEFProfileStorageBuildFolderTests {
    static let support = URL(fileURLWithPath: "/Users/me/Library/Application Support", isDirectory: true)

    static func root(_ bundleID: String, tag: String?) -> String {
        CEFProfileStorage.forApplication(bundleIdentifier: bundleID, build: BuildIdentity(bundleID: bundleID, bundledTag: tag),
                                         applicationSupport: support).root.path
    }

    @Test func aDevCopyKeepsItsOwnProfiles() {
        #expect(Self.root("com.cmuxterm.app.debug", tag: "copy-a") == Self.support.path + "/com.cmuxterm.app.debug--copy-a/Chromium")
        #expect(Self.root("com.cmuxterm.app.debug", tag: "copy-b") == Self.support.path + "/com.cmuxterm.app.debug--copy-b/Chromium")
        #expect(Self.root("com.cmuxterm.app.debug.my-tag", tag: "my-tag") == Self.support.path + "/com.cmuxterm.app.debug.my-tag/Chromium")
        #expect(Self.root("com.cmuxterm.app.nightly", tag: nil) == Self.support.path + "/com.cmuxterm.app.nightly/Chromium")
        #expect(Self.root("com.cmuxterm.app", tag: nil) == Self.support.path + "/com.cmuxterm.app/Chromium")
    }
}
