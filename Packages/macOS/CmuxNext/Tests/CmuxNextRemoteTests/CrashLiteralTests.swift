import Foundation
import Testing
@testable import CmuxNextRemote

/// Crash program: the install base is a literal that must parse.
@Suite struct RemoteCrashLiteralTests {
    @Test func installBaseParses() {
        #expect(RemoteInstallPlan.base.absoluteString == "https://files.cmux.com/cmux-tui")
    }
}
