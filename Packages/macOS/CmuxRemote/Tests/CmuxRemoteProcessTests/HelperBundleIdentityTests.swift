// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxRemoteHost
import CmuxRemoteWire
import Foundation
import Testing

/// The supervisor lives inside the Computer Use helper, whose bundle is not its own: its own
/// path and its build stamp never come from the bundle's main executable.
@Suite struct HelperBundleIdentityTests {
    @Test func ownExecutableIsThisProcessFileNotTheBundlesMainExecutable() throws {
        let path = OwnExecutable.path(fallback: "/fallback")
        #expect(path.hasPrefix("/"))
        #expect(path != "/fallback")
        #expect(FileManager.default.isExecutableFile(atPath: path))
    }

    @Test func buildStampTellsBuildsApartWithoutASourceTree() {
        // The Computer Use helper's Info.plist: a version, no CmuxRemoteSourceTree.
        let helper: [String: Any] = ["CFBundleVersion": "42"]
        #expect(RemoteHost.buildStamp(info: helper, codeHash: "0123456789ab") == "42+cdhash-0123456789ab")
        #expect(RemoteHost.buildStamp(info: helper, codeHash: "ba9876543210") != RemoteHost.buildStamp(info: helper, codeHash: "0123456789ab"))
        // A bundle that names its source tree keeps it.
        let named: [String: Any] = ["CFBundleVersion": "42", "CmuxRemoteSourceTree": "tree"]
        #expect(RemoteHost.buildStamp(info: named, codeHash: "0123456789ab") == "42+tree")
        // Unsigned, no plist: empty, never a crash.
        #expect(RemoteHost.buildStamp(info: nil, codeHash: nil) == "")
    }
}
