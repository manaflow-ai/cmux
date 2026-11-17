import CmuxNextCompat
import Foundation
@testable import CmuxNextMobileHost
import Testing

/// hostd's state (the phone pairing, its keys) is per build: two Debug copies of one bundle id with their own tags
/// never share a pairing. Tagged DEV builds, NIGHTLY and release keep their bundle id's folder.
@Suite struct IPhoneHostStateRootTests {
    static let support = URL(fileURLWithPath: "/Users/me/Library/Application Support/cmux-next", isDirectory: true)

    static func root(_ bundleID: String?, tag: String?) -> String {
        IPhoneHostService.stateRoot(applicationSupport: support, bundleID: bundleID,
                                    build: BuildIdentity(bundleID: bundleID, bundledTag: tag)).path
    }

    @Test func aDevCopyKeepsItsOwnPairing() {
        #expect(Self.root("com.cmuxterm.app.debug", tag: "copy-a") == support.path + "/com.cmuxterm.app.debug--copy-a")
        #expect(Self.root("com.cmuxterm.app.debug", tag: "copy-b") == support.path + "/com.cmuxterm.app.debug--copy-b")
        #expect(Self.root("com.cmuxterm.app.debug.my-tag", tag: "my-tag") == support.path + "/com.cmuxterm.app.debug.my-tag")
        #expect(Self.root("com.cmuxterm.app.nightly", tag: nil) == support.path + "/com.cmuxterm.app.nightly")
        #expect(Self.root(nil, tag: nil) == support.path + "/com.cmuxterm.app.next")
    }
}
