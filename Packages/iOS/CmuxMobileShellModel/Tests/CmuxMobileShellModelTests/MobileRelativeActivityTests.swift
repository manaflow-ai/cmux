import Foundation
import Testing

@testable import CmuxMobileShellModel

@Suite struct MobileRelativeActivityTests {
    /// A fixed reference instant so every bucket assertion is wall-clock free.
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    @Test func placeholderTimestampsHaveNoBucket() {
        #expect(MobileRelativeActivity.bucket(for: .distantPast, now: now) == .none)
        #expect(MobileRelativeActivity.bucket(for: Date(timeIntervalSince1970: 0), now: now) == .none)
        #expect(MobileRelativeActivity.bucket(for: Date(timeIntervalSince1970: 1), now: now) == .none)
    }

    @Test func subMinuteAndClockSkewReadNow() {
        #expect(MobileRelativeActivity.bucket(for: now, now: now) == .now)
        #expect(MobileRelativeActivity.bucket(for: now.addingTimeInterval(-59), now: now) == .now)
        // A Mac clock slightly ahead of the phone must read "now", never a
        // negative or nonsense value.
        #expect(MobileRelativeActivity.bucket(for: now.addingTimeInterval(30), now: now) == .now)
    }

    @Test func bucketsAreDeterministicGivenInjectedNow() {
        #expect(MobileRelativeActivity.bucket(for: now.addingTimeInterval(-60), now: now) == .minutes(1))
        #expect(MobileRelativeActivity.bucket(for: now.addingTimeInterval(-5 * 60), now: now) == .minutes(5))
        #expect(MobileRelativeActivity.bucket(for: now.addingTimeInterval(-59 * 60), now: now) == .minutes(59))
        #expect(MobileRelativeActivity.bucket(for: now.addingTimeInterval(-60 * 60), now: now) == .hours(1))
        #expect(MobileRelativeActivity.bucket(for: now.addingTimeInterval(-23 * 3600), now: now) == .hours(23))
        #expect(MobileRelativeActivity.bucket(for: now.addingTimeInterval(-24 * 3600), now: now) == .days(1))
        #expect(MobileRelativeActivity.bucket(for: now.addingTimeInterval(-6 * 86400), now: now) == .days(6))
        #expect(MobileRelativeActivity.bucket(for: now.addingTimeInterval(-7 * 86400), now: now) == .monthDay)
    }
}
