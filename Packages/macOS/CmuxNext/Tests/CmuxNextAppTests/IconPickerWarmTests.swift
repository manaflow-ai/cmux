@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextPages
import Testing

/// The icon picker is warm before its first open (cx-ag5.9.2): the app prepares its panel, page
/// and symbol catalog at an idle moment after launch, so the first Set Icon opens as fast as later
/// ones instead of loading the catalog and a cold page first.
@MainActor
struct IconPickerWarmTests {
    @Test func preparingMakesThePickerWarmBeforeAnyOpen() async {
        let picker = IconPickerService(services: nil, webUI: .iconPickerTestHost())
        #expect(!picker.isWarm)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            picker.prepare { done.resume() }
        }
        #expect(picker.isWarm)
    }
}

extension WebUIHost {
    /// A page host with no Chromium and no open panel: the picker's page is WebKit, as in the app.
    static func iconPickerTestHost() -> WebUIHost {
        WebUIHost(chromium: nil, openPanel: nil, memoryPressure: MemoryPressureEvents(source: ManualMemoryPressureSource()),
                  clock: ContinuousClock())
    }
}
