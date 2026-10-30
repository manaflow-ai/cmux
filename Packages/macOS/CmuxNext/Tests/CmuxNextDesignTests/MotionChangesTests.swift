import AppKit
@testable import CmuxNextDesign
import Testing

/// One direct subscription carries every motion-setting change (Leo #26385, #25671): Home and the
/// Chief pet subscribe here instead of each observing the cmux and system notifications.
@MainActor @Suite(.serialized) struct MotionChangesTests {
    @Test func eachChangeReachesASubscriberUntilItEnds() {
        let system = NotificationCenter()
        let changes = MotionChanges(systemCenter: system)
        var heard: [MotionChange] = []
        let subscription = changes.subscribe { heard.append($0) }

        changes.post(.speed)
        changes.post(.reduceMotion)
        system.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(heard == [.speed, .reduceMotion, .systemReduceMotion])

        subscription.cancel()
        changes.post(.speed)
        #expect(heard.count == 3, "a cancelled subscription heard a change")
    }

    @Test func aReleasedSubscriptionHearsNothing() {
        let changes = MotionChanges(systemCenter: NotificationCenter())
        var heard = 0
        _ = changes.subscribe { _ in heard += 1 }
        changes.post(.speed)
        #expect(heard == 0)
    }

    /// The app's instance hears the test override and the settings that post the notifications.
    @Test func theAppsInstanceHearsTheOverrideAndTheSpeed() {
        var heard: [MotionChange] = []
        let subscription = Motion.changes.subscribe { heard.append($0) }
        defer { subscription.cancel() }
        Motion.reduceMotionOverride = true
        Motion.reduceMotionOverride = nil
        let speed = DesignSettings.shared.animationSpeed
        DesignSettings.shared.animationSpeed = speed == .fast ? .normal : .fast
        DesignSettings.shared.animationSpeed = speed
        #expect(heard == [.reduceMotion, .reduceMotion, .speed, .speed])
    }
}
