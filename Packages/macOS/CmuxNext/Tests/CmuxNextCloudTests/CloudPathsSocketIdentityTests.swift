@testable import CmuxNextCloud
import Foundation
import Testing

/// NEXT's own folder holds Cloud's state now (cmuxterm-hq goals/next-store-out-of-classic.md); the link
/// socket keeps the name builds before the move gave it, so a running link is still found after the move.
struct CloudPathsSocketIdentityTests {
    @Test func theStandardRootIsNEXTsAndItsSocketNameIsUnchanged() {
        let paths = CloudPaths.standard(bundleID: "com.cmuxterm.app.nightly")
        #expect(paths.root.path.hasSuffix("/Application Support/cmux-next/com.cmuxterm.app.nightly/cloud-next"))
        let before = CloudPaths(root: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/cmux/com.cmuxterm.app.nightly/cloud-next", directoryHint: .isDirectory))
        #expect(paths.linkSocket(machineID: "m1") == before.linkSocket(machineID: "m1"))
        #expect(paths.namespaced("dev").linkSocket(machineID: "m1")
            == CloudPaths(root: before.root.appending(path: "dev", directoryHint: .isDirectory)).linkSocket(machineID: "m1"))
    }
}
