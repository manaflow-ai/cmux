@testable import CmuxNextDesign
import Testing

/// The startup of an update relaunch nobody clicked: windows come in without the keys, so the
/// app the user is in keeps the keyboard; a launch without it keeps its plans.
@Suite struct WindowActivationStartsBehindTests {
    @Test func presentedAndRaisedWindowsComeInWithoutTheKeys() {
        for intent: WindowActivation.Intent in [.present, .raise] {
            #expect(WindowActivation.plan(intent, noActivate: false, testScreen: false, startsBehind: true)
                == .init(order: .orderFront, activatesApp: false))
            #expect(WindowActivation.plan(intent, noActivate: false, testScreen: false)
                == .init(order: .makeKeyAndOrderFront, activatesApp: false))
        }
    }

    @Test func aUsersFocusAndNoActivateLaunchesKeepTheirPlans() {
        #expect(WindowActivation.plan(.focus, noActivate: false, testScreen: false, startsBehind: true)
            == .init(order: .makeKeyAndOrderFront, activatesApp: true))
        #expect(WindowActivation.plan(.present, noActivate: true, testScreen: false, startsBehind: true)
            == WindowActivation.plan(.present, noActivate: true, testScreen: false))
    }
}
