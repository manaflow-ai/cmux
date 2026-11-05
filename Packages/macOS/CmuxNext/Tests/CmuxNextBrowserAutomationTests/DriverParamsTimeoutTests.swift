import Foundation
import Testing
@testable import CmuxNextBrowserAutomation

/// `timeoutMs` comes from the driver call's params: any finite number passed `optionalNumber`, and
/// `Int64(_:)` of 1e30 traps.
@Suite struct DriverParamsTimeoutTests {
    private func timeout(_ value: Double) throws -> Duration? {
        try DriverParams(method: "page.goto", json: .object(["timeoutMs": .number(value)])).timeout()
    }

    @Test func aHugeTimeoutIsAFarDeadlineNotATrap() throws {
        for value in [1e30, 9.3e18, Double.greatestFiniteMagnitude] {
            let deadline = try #require(try timeout(value))
            #expect(deadline > .seconds(86_400))
        }
    }

    @Test func ordinaryTimeoutsKeepTheirMeaning() throws {
        #expect(try timeout(1_500) == .milliseconds(1_500))
        #expect(try timeout(0) == nil)
        #expect(try timeout(-5) == nil)
    }
}
