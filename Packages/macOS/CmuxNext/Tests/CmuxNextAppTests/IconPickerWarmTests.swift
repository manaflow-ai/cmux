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
        let host = WebUIHost.iconPickerTestHost()
        let picker = IconPickerService(services: nil, webUI: host)
        #expect(!picker.isWarm)
        #expect(host.openPages.isEmpty)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            picker.prepare { done.resume() }
        }
        #expect(picker.isWarm)
        // The warm page is opened through the injected host, not around it.
        #expect(host.openPages.count == 1)
    }
}

extension WebUIHost {
    /// A page host with no Chromium host and no open panel, so the picker's page is WebKit.
    static func iconPickerTestHost() -> WebUIHost {
        WebUIHost(chromium: nil, openPanel: nil, memory: ManualMemoryLevelRegistry())
    }
}
