@testable import CmuxNextBrowser
import CmuxNextTrace
import CmuxNextWakeups
import Testing

/// Chromium names the fork's API version in the crash-key page once it is ready, and the
/// version stays through a later failure or shutdown.
@MainActor
struct CEFCrashKeyPageTests {
    @Test func theForkAPIVersionIsNamedWhenChromiumIsReady() {
        let keys = CrashKeySlots(), page = CrashKeyPage(identity: .init(role: .app))
        keys.page.attach(page)
        keys.noteCEF(.loading, forkAPIVersion: 31)
        #expect(page.value(.cefAPIVersion) == 0, "a version before Chromium is ready")
        #expect(keys.value(.cefState) == CrashKeySlots.CEFState.initializing.rawValue)
        keys.noteCEF(.ready, forkAPIVersion: 31)
        #expect(page.value(.cefAPIVersion) == 31)
        keys.noteCEF(.shutDown, forkAPIVersion: 0)
        #expect(page.value(.cefAPIVersion) == 31, "shutting down cleared the version")
        #expect(keys.value(.cefState) == CrashKeySlots.CEFState.shutDown.rawValue)
    }
}
