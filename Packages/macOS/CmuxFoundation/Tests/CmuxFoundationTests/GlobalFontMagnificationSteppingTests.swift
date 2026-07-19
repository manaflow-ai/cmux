import Foundation
import Testing

@testable import CmuxFoundation

/// Behavior tests for ``GlobalFontMagnification/increasePercent()`` /
/// ``GlobalFontMagnification/decreasePercent()``: one step per call, clamped to
/// the supported range, with a live-update notification on every change.
@Suite struct GlobalFontMagnificationSteppingTests {
    private func makeSubject(percent: Int?) -> (GlobalFontMagnification, UserDefaults, NotificationCenter) {
        let suiteName = "GlobalFontMagnificationSteppingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        if let percent {
            defaults.set(percent, forKey: GlobalFontMagnification.percentKey)
        }
        let center = NotificationCenter()
        return (GlobalFontMagnification(userDefaults: defaults, notificationCenter: center), defaults, center)
    }

    @Test func increaseStepsUpByOneStepAndNotifies() {
        let (magnification, _, center) = makeSubject(percent: 100)
        var notified = 0
        let observer = center.addObserver(
            forName: GlobalFontMagnification.didChangeNotification, object: nil, queue: nil
        ) { _ in notified += 1 }
        defer { center.removeObserver(observer) }

        #expect(magnification.increasePercent())
        #expect(magnification.storedPercent == 100 + GlobalFontMagnification.stepPercent)
        #expect(notified == 1)
    }

    @Test func decreaseStepsDownByOneStep() {
        let (magnification, _, _) = makeSubject(percent: 100)
        #expect(magnification.decreasePercent())
        #expect(magnification.storedPercent == 100 - GlobalFontMagnification.stepPercent)
    }

    @Test func increaseAtMaximumIsRejectedWithoutNotifying() {
        let (magnification, _, center) = makeSubject(percent: GlobalFontMagnification.maximumPercent)
        var notified = 0
        let observer = center.addObserver(
            forName: GlobalFontMagnification.didChangeNotification, object: nil, queue: nil
        ) { _ in notified += 1 }
        defer { center.removeObserver(observer) }

        #expect(!magnification.increasePercent())
        #expect(magnification.storedPercent == GlobalFontMagnification.maximumPercent)
        #expect(notified == 0)
    }

    @Test func decreaseAtMinimumIsRejected() {
        let (magnification, _, _) = makeSubject(percent: GlobalFontMagnification.minimumPercent)
        #expect(!magnification.decreasePercent())
        #expect(magnification.storedPercent == GlobalFontMagnification.minimumPercent)
    }

    @Test func stepsFromUnsetDefaultsStartAtDefaultPercent() {
        let (magnification, _, _) = makeSubject(percent: nil)
        #expect(magnification.increasePercent())
        #expect(magnification.storedPercent == GlobalFontMagnification.defaultPercent + GlobalFontMagnification.stepPercent)
    }
}
