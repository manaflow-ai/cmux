@testable import CmuxNextApp
import Testing

/// The icon picker is warm before its first open (cx-ag5.9.2): the app prepares its panel, page
/// and symbol catalog at the first menu (where Set Icon is; never at launch, `MenuTracking.onFirstMenu`),
/// so the first Set Icon opens as fast as later ones instead of loading the catalog and a cold page first.
@MainActor
struct IconPickerWarmTests {
    @Test func preparingMakesThePickerWarmBeforeAnyOpen() async {
        let picker = IconPickerService(services: nil)
        #expect(!picker.isWarm)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            picker.prepare { done.resume() }
        }
        #expect(picker.isWarm)
    }

    /// At launch idle the app loads only the symbol catalog (no WebKit process), so a first open with no earlier sign
    /// of intent (a socket call, a custom shortcut) waits only for its page, not for the catalog too.
    @Test func preparingTheCatalogMakesNoPage() async {
        let picker = IconPickerService(services: nil)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            picker.prepare(page: false) { done.resume() }
        }
        #expect(!picker.isWarm, "loading the catalog made the WebKit page")
    }
}

/// The warm picker is freed after its idle limit with no open (CMUX-571: about 100 MB of WebKit processes held for
/// good after one menu), and the next sign of intent makes it again.
@MainActor
struct IconPickerReleaseTests {
    @Test func releaseFreesTheWarmPickerAndAPrepareMakesItAgain() async {
        let picker = IconPickerService(services: nil)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in picker.prepare { done.resume() } }
        #expect(picker.isWarm)
        picker.release()
        #expect(!picker.isWarm, "release kept the page")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in picker.prepare { done.resume() } }
        #expect(picker.isWarm, "a sign of intent after a release made no page")
    }

    @Test func theIdleLimitFreesAnUnusedPicker() async throws {
        let picker = IconPickerService(services: nil)
        picker.idleLimit = .milliseconds(50)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in picker.prepare { done.resume() } }
        #expect(picker.isWarm)
        for _ in 0..<100 where picker.isWarm { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!picker.isWarm, "an unused picker stayed made past its idle limit")
    }
}
