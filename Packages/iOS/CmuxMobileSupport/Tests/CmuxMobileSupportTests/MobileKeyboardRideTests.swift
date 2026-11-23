import Foundation
import Testing
@testable import CmuxMobileSupport

/// What a keyboard-following layout is given against what the system keyboard
/// notification carries, checked without a device: a ride that drifts from the
/// keyboard's own motion fails here before any simulator bench runs.
@Suite struct MobileKeyboardRideTests {
    /// One frame at 120 Hz: the stop condition's finish offset.
    private let oneFrame: TimeInterval = 1.0 / 120

    /// The values iOS 26 posts for the software keyboard's show and hide.
    private let keyboardShow: (duration: NSNumber, curve: NSNumber) = (NSNumber(value: 0.383), NSNumber(value: 7))
    private let keyboardHide: (duration: NSNumber, curve: NSNumber) = (NSNumber(value: 0.383), NSNumber(value: 7))

    @Test func keyboardCurveRidesTheKeyboardsSpringOnShowAndHide() {
        for posted in [keyboardShow, keyboardHide] {
            let ride = MobileKeyboardRide(notifiedDuration: posted.duration, notifiedCurve: posted.curve)
            #expect(ride.motion == .spring(response: MobileKeyboardRide.keyboardSpringResponse))
            // The keyboard runs the same spring, so the ride settles when it does.
            let keyboardSettle = MobileKeyboardRide.criticallyDampedSettle(response: 0.2667)
            #expect(abs(ride.settleSeconds - keyboardSettle) <= oneFrame)
        }
    }

    /// The bug this replaced: a nested `UIView.animate` over the notified
    /// 0.383 s with curve 7 as a timing function settled well after the
    /// keyboard's spring.
    @Test func keyboardCurveIsNeverATimingFunctionOverTheNotifiedDuration() {
        let ride = MobileKeyboardRide(duration: 0.383, curve: 7)
        #expect(ride.motion != .timed(duration: 0.383, curve: 7))
        let oldSettle: TimeInterval = 0.383
        #expect(oldSettle - ride.settleSeconds > oneFrame)
    }

    @Test func otherCurvesUseTheNotifiedDurationAndCurveExactly() {
        for curve in 0...3 {
            let ride = MobileKeyboardRide(notifiedDuration: NSNumber(value: 0.25), notifiedCurve: NSNumber(value: curve))
            #expect(ride.motion == .timed(duration: 0.25, curve: curve))
            #expect(ride.settleSeconds == 0.25)
            #expect(ride.optionsRawValue >> 16 == UInt(curve))
        }
    }

    @Test func everyRideIsInterruptibleFromTheDrawnPosition() {
        for (duration, curve) in [(0.383, 7), (0.25, 0), (0.25, 3), (0.0, 7)] {
            let raw = MobileKeyboardRide(duration: duration, curve: curve).optionsRawValue
            #expect(raw & MobileKeyboardRide.allowUserInteraction != 0)
            #expect(raw & MobileKeyboardRide.beginFromCurrentState != 0)
            #expect(raw & MobileKeyboardRide.overrideInheritedDuration != 0)
            #expect(raw & MobileKeyboardRide.overrideInheritedCurve != 0)
        }
    }

    @Test func noDurationLaysOutAtOnce() {
        #expect(MobileKeyboardRide(notifiedDuration: nil, notifiedCurve: NSNumber(value: 7)).motion == .immediate)
        #expect(MobileKeyboardRide(notifiedDuration: NSNumber(value: 0), notifiedCurve: nil).motion == .immediate)
        #expect(MobileKeyboardRide(duration: 0, curve: 7).settleSeconds == 0)
    }

    @Test func notificationValuesParseAsUIKitPostsThem() {
        #expect(MobileKeyboardRide.duration(NSNumber(value: 0.383)) == 0.383)
        #expect(MobileKeyboardRide.duration(0.25 as TimeInterval) == 0.25)
        #expect(MobileKeyboardRide.duration(nil) == 0)
        #expect(MobileKeyboardRide.curve(NSNumber(value: 7)) == 7)
        #expect(MobileKeyboardRide.curve(3) == 3)
        #expect(MobileKeyboardRide.curve(nil) == 0)
    }

    @Test func keyboardSpringSettlesInsideTheNotifiedDuration() {
        let settle = MobileKeyboardRide.criticallyDampedSettle(response: MobileKeyboardRide.keyboardSpringResponse)
        #expect(settle > 0.2 && settle < 0.383)
    }
}

#if canImport(UIKit)
import UIKit

extension MobileKeyboardRideTests {
    /// The raw option values match UIKit's, so the pure ride is what UIKit runs.
    @Test func optionRawValuesMatchUIKit() {
        #expect(MobileKeyboardRide.allowUserInteraction == UIView.AnimationOptions.allowUserInteraction.rawValue)
        #expect(MobileKeyboardRide.beginFromCurrentState == UIView.AnimationOptions.beginFromCurrentState.rawValue)
        #expect(MobileKeyboardRide.overrideInheritedDuration == UIView.AnimationOptions.overrideInheritedDuration.rawValue)
        #expect(MobileKeyboardRide.overrideInheritedCurve == UIView.AnimationOptions.overrideInheritedCurve.rawValue)
        #expect(UIView.AnimationOptions.curveEaseOut.rawValue == 2 << 16)
    }

    @MainActor @Test func transitionFromANotificationRidesWithItsValues() {
        let note = Notification(
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: CGRect(x: 0, y: 500, width: 400, height: 336),
                UIResponder.keyboardAnimationDurationUserInfoKey: NSNumber(value: 0.383),
                UIResponder.keyboardAnimationCurveUserInfoKey: NSNumber(value: 7),
            ]
        )
        let transition = MobileKeyboardTransition(notification: note)
        #expect(transition?.duration == 0.383)
        #expect(transition?.curve == 7)
    }
}
#endif
