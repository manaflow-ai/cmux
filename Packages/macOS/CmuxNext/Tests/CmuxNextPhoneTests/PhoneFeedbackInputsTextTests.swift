@testable import CmuxNextPhone
import Foundation
import Testing

/// The phone feedback summary's counts follow labels ("1 inputs, 1 taps" is gone).
@MainActor
struct PhoneFeedbackInputsTextTests {
    @Test func countsFollowLabels() {
        let latin = Locale(identifier: "en_US@numbers=latn")
        #expect(PhoneFeedbackClip.inputs(1, taps: 1, preferredLocalizations: ["en"], locale: latin) == "Inputs: 1, taps: 1")
        #expect(PhoneFeedbackClip.inputs(12, taps: 3, preferredLocalizations: ["ru"], locale: latin) == "Ввод: 12, касания: 3")
    }
}
