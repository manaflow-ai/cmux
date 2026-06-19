import Foundation
import Testing
@testable import CmuxControlSocket

@Suite("FeedPushWaitTimeout")
struct FeedPushWaitTimeoutTests {
    @Test("absent key yields a zero timeout")
    func absentYieldsZero() {
        #expect(FeedPushWaitTimeout.parse(rawValue: nil) == .success(.init(rawValue: nil)!))
        #expect(FeedPushWaitTimeout(rawValue: nil)?.seconds == 0)
    }

    @Test("NSNumber, Double, and Int all coerce through doubleValue")
    func numericCoercion() {
        #expect(FeedPushWaitTimeout(rawValue: NSNumber(value: 30))?.seconds == 30)
        #expect(FeedPushWaitTimeout(rawValue: 45.5)?.seconds == 45.5)
        #expect(FeedPushWaitTimeout(rawValue: 12)?.seconds == 12)
        // Legacy `as? NSNumber` coerced a JSON boolean to 1/0 via doubleValue.
        #expect(FeedPushWaitTimeout(rawValue: true)?.seconds == 1)
    }

    @Test("bounds are the closed interval 0...120")
    func boundsInclusive() {
        #expect(FeedPushWaitTimeout(rawValue: 0)?.seconds == 0)
        #expect(FeedPushWaitTimeout(rawValue: 120)?.seconds == 120)
        #expect(FeedPushWaitTimeout.parse(rawValue: 120.000001) == .failure(.outOfRange))
        #expect(FeedPushWaitTimeout.parse(rawValue: -1) == .failure(.outOfRange))
    }

    @Test("non-finite values are out of range")
    func nonFinite() {
        #expect(FeedPushWaitTimeout.parse(rawValue: Double.nan) == .failure(.outOfRange))
        #expect(FeedPushWaitTimeout.parse(rawValue: Double.infinity) == .failure(.outOfRange))
    }

    @Test("a non-numeric value is rejected as non-numeric")
    func nonNumeric() {
        #expect(FeedPushWaitTimeout.parse(rawValue: "soon") == .failure(.nonNumeric))
        #expect(FeedPushWaitTimeout(rawValue: "soon") == nil)
    }
}
