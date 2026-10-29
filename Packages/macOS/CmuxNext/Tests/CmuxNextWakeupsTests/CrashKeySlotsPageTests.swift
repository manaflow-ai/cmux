import CmuxNextTrace
import CmuxNextWakeups
import Testing

/// The crash-key page keys the app's crash keys set for their owners: the last input time,
/// the window, terminal and browser counts. Each reads back from the attached page, and nothing is stored before a
/// page is attached.
@Suite struct CrashKeySlotsPageTests {
    @Test func aKeyBeforeThePageIsAttachedGoesNowhere() {
        let keys = CrashKeySlots()
        keys.noteWindows(3)
        #expect(keys.page.value(.windowCount) == 0)
        let page = CrashKeyPage(identity: .init(role: .app))
        #expect(keys.page.attach(page))
        #expect(!keys.page.attach(CrashKeyPage(identity: .init(role: .app))), "a second page replaced the first")
        #expect(page.value(.windowCount) == 0, "a key stored before the attach reached the page")
        keys.noteWindows(3)
        #expect(page.value(.windowCount) == 2)
    }

    @Test func theLastInputTimeIsStoredInNanoseconds() {
        let keys = CrashKeySlots(), page = CrashKeyPage(identity: .init(role: .app))
        keys.page.attach(page)
        keys.noteInput(uptimeSeconds: 12.5)
        #expect(page.value(.lastInputUptime) == 12_500_000_000)
        keys.noteInput(uptimeSeconds: 0)
        #expect(page.value(.lastInputUptime) == 12_500_000_000, "an event with no time replaced the last one")
    }

    @Test func countsAreStoredAsBuckets() {
        let keys = CrashKeySlots(), page = CrashKeyPage(identity: .init(role: .app))
        keys.page.attach(page)
        keys.noteWindows(1)
        keys.noteTerminals(37)
        keys.noteBrowsers(chromium: 5, webKit: 0)
        let snapshot = page.snapshot()
        #expect(snapshot[.windowCount] == 1)
        #expect(snapshot[.terminalCount] == 32)
        #expect(snapshot[.chromiumBrowserCount] == 4)
        #expect(snapshot[.webKitViewCount] == 0)
        keys.noteTerminals(0)
        #expect(page.value(.terminalCount) == 0)
    }
}
