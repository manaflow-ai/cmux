import Testing
@testable import CmuxMobileShellUI

@Suite
struct MobileSignOutHookTests {
    @Test
    func localPreparationCompletesBeforeCapturedTokenTeardown() async {
        let recorder = MobileSignOutHookRecorder()
        let hook = MobileSignOutHook {
            await recorder.record("local")
            return { accessToken, refreshToken in
                await recorder.record("remote:\(accessToken ?? "nil"):\(refreshToken ?? "nil")")
            }
        }

        let teardown = await hook.prepare()
        #expect(await recorder.values() == ["local"])

        await teardown("access", "refresh")
        #expect(await recorder.values() == ["local", "remote:access:refresh"])
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
