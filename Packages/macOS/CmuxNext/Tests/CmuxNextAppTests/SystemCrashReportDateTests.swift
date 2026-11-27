@testable import CmuxNextCrashReporting
import Foundation
import Testing

/// A report's time fields are read from a file macOS wrote; a corrupt one must not crash the
/// launch-time scan of DiagnosticReports (`clock[0]` was out of range for a lone ".").
nonisolated struct SystemCrashReportDateTests {
    @Test func aTimeFieldWithoutDigitsIsNil() {
        #expect(SystemCrashReport.date("2026-10-27 . -0700") == nil)
        #expect(SystemCrashReport.date("2026-10-27 .. -0700") == nil)
    }

    @Test func aRealTimeKeepsItsFraction() throws {
        let date = try #require(SystemCrashReport.date("2026-10-27 21:03:37.6504 -0700"))
        let whole = try #require(SystemCrashReport.date("2026-10-27 21:03:37 -0700"))
        #expect(abs(date.timeIntervalSince(whole) - 0.6504) < 0.0001)
    }
}
