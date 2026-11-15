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
