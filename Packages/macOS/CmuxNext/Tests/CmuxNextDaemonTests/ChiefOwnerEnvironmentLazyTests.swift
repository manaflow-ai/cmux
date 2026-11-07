import Foundation
import Testing
@testable import CmuxNextDaemon

/// cmuxterm-hq#6338: the Chief owner's environment held the main thread 2.86 s at launch
/// (`ChiefConversationOwner.start` -> `ownerEnvironment` -> acpmux's team-signature check, a read
/// of the whole executable). The launcher now takes that environment as a provider that runs only
/// when `server ensure` spawns an owner, never while the launcher is made.
struct ChiefOwnerEnvironmentLazyTests {
    @Test func theOwnersEnvironmentIsBuiltOnlyWhenAnOwnerSpawns() async throws {
        let state = FileManager.default.temporaryDirectory
            .appendingPathComponent("chief-owner-env-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: state) }
        let calls = Calls()
        let launcher = try DaemonLauncher.forChief(
            session: "chief-owner-env-test", stateDirectory: state,
            processEnvironment: [DaemonLauncher.binaryOverrideKey: "/bin/sh"],
            ownerEnvironment: {
                await calls.bump()
                // The slow signature check this provider stands for.
                try? await Task.sleep(for: .milliseconds(500))
                return ["PATH": "/usr/bin", "CMUX_TUI_CHIEF_BRAINS": "{}", "CMUX_TAG": "a-build"]
            })

        #expect(await calls.count == 0)

        let environment = await launcher.ensureEnvironment()
        #expect(await calls.count == 1)
        #expect(environment["CMUX_TUI_CHIEF_BRAINS"] == "{}")
        #expect(environment["PATH"] == "/usr/bin")
        // Still only the Chief's kept variables: never a build's identity.
        #expect(environment["CMUX_TAG"] == nil)
        #expect(environment["CMUX_TUI_STATE_DIR"] == state.path)
    }
}

private actor Calls {
    var count = 0
    func bump() { count += 1 }
}
