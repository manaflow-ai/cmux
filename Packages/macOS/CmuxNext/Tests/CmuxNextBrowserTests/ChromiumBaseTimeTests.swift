import Foundation
import Testing
@testable import CmuxNextBrowser

/// A cookie's dates come from another browser's files, where a far-future expiry is common
/// (Safari stores a raw double, Firefox a raw Int64). `Int64(_:)` of such a Double traps.
@Suite struct ChromiumBaseTimeTests {
    @Test func aFarFutureOrNonFiniteDateIsClampedNotATrap() {
        let dates = [Date(timeIntervalSinceReferenceDate: 1e300), Date(timeIntervalSince1970: .infinity),
                     Date(timeIntervalSince1970: 1e13), Date(timeIntervalSince1970: -.infinity)]
        for date in dates {
            #expect(Int64(ChromiumCookieWrite.baseTime(date)) != nil)
        }
        #expect(ChromiumCookieWrite.baseTime(Date(timeIntervalSince1970: .infinity)) == String(Int64(9.2e18)))
    }

    @Test func anOrdinaryDateIsMicrosecondsSince1601() {
        #expect(ChromiumCookieWrite.baseTime(Date(timeIntervalSince1970: 0)) == "11644473600000000")
        #expect(ChromiumCookieWrite.baseTime(nil) == "0")
    }
}
