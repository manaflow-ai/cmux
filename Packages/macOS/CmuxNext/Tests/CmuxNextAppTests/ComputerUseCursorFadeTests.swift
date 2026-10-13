import Foundation
import Testing
@testable import CmuxNextApp

/// cx-ujus: the computer-use cursor stayed on screen after a run. The
/// helper removes it only when the agent session ends, so its idle fade is
/// what hides it once the agent stops acting; `--idle-hide-ms 0` turned that
/// fade off.
struct ComputerUseCursorFadeTests {
    @Test func theHelperFadesItsCursorSoonAfterTheLastAction() throws {
        let argv = ComputerUseHelperDaemon.arguments(socketPath: "/tmp/cua.sock", ownerPID: 42)
        let flag = try #require(argv.firstIndex(of: "--idle-hide-ms"), "the helper must be told when to fade: \(argv)")
        let ms = try #require(Double(argv[argv.index(after: flag)]))
        #expect(ms > 0, "0 disables the fade, so the cursor stays after the run")
        #expect(ms <= 15_000, "the cursor should leave soon after the last action, not stay for the session")
    }
}
