import CmuxMobileShell
import Foundation
import Testing

@Suite
final class MobileMacUpdateHintDismissalStoreTests {
    private let suiteName: String
    private let defaults: UserDefaults
    private let store: MobileMacUpdateHintDismissalStore

    init() {
        suiteName = "mac-update-hint-dismissal-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = MobileMacUpdateHintDismissalStore(defaults: defaults)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test
    func dismissingSignaturePersistsExactMatch() {
        store.dismiss(macDeviceID: "mac-a", signature: "cap.a>=2.0")
        #expect(store.isDismissed(macDeviceID: "mac-a", signature: "cap.a>=2.0"))
    }

    @Test
    func differentSignatureRearmsHint() {
        store.dismiss(macDeviceID: "mac-a", signature: "cap.a>=2.0")
        #expect(!store.isDismissed(macDeviceID: "mac-a", signature: "cap.a,cap.b>=3.0"))
    }

    @Test
    func dismissalIsScopedToMac() {
        store.dismiss(macDeviceID: "mac-a", signature: "cap.a>=2.0")
        #expect(!store.isDismissed(macDeviceID: "mac-b", signature: "cap.a>=2.0"))
    }
}
