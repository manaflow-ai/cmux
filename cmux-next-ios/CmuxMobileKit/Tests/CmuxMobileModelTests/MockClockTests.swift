import Foundation
import Testing
@testable import CmuxMobileModel

/// `-cmux-mobile-fixed-now` pins the mock data's clock (the App Review gate's stills).
@Suite struct MockClockTests {
    @Test func theLaunchArgumentFixesTheInstant() {
        #if DEBUG
        #expect(MockClock.fixedNow(arguments: ["app", "-cmux-mobile-fixed-now", "1790976000"])
            == Date(timeIntervalSince1970: 1_790_976_000))
        #endif
        #expect(MockClock.fixedNow(arguments: ["app"]) == nil)
        #expect(MockClock.fixedNow(arguments: ["app", "-cmux-mobile-fixed-now"]) == nil)
        #expect(MockClock.fixedNow(arguments: ["app", "-cmux-mobile-fixed-now", "soon"]) == nil)
    }
}
