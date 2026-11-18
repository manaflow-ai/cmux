import CmuxNextCompat
@testable import CmuxNextComputerUse
import Foundation
import Testing

/// The helper's runtime folder is NEXT's own, under `cmux-next`, not in classic cmux's `cmux`
/// (cmuxterm-hq goals/next-store-out-of-classic.md); the moved folder's scope name stays the same.
struct ComputerUseHelperStateDirectoryTests {
    @Test func theStateDirectoryIsUnderNextsFolder() {
        let support = URL(fileURLWithPath: "/Users/a/Library/Application Support", isDirectory: true)
        let state = ComputerUseHelperDaemon.defaultStateDirectory(bundleID: "com.cmuxterm.app.nightly", applicationSupport: support)
        #expect(state.path == "/Users/a/Library/Application Support/cmux-next/cmux-cua/runtime/73ff36dc45525a51/state")
        #expect(ComputerUseHelperDaemon.scope("com.cmuxterm.app.nightly") == NextSupport.computerUseScope("com.cmuxterm.app.nightly"))
    }
}
