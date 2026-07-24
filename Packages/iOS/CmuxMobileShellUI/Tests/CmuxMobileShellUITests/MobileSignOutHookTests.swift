import Testing
@testable import CmuxMobileShellUI

@Suite
struct MobileSignOutHookTests {
    @Test
    @MainActor
    func beginReturnsCapturedTokenTeardownSynchronously() async {
        let recorder = MobileSignOutHookRecorder()
        let hook = MobileSignOutHook {
            return { accessToken, refreshToken in
                await recorder.record("remote:\(accessToken ?? "nil"):\(refreshToken ?? "nil")")
            }
        }

        let teardown = hook.begin()
        #expect(await recorder.values().isEmpty)

        await teardown("access", "refresh")
        #expect(await recorder.values() == ["remote:access:refresh"])
    }
}

private actor MobileSignOutHookRecorder {
    private var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func values() -> [String] {
        events
    }
}
