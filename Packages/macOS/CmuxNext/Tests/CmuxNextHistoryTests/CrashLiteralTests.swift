import Foundation
import Testing
@testable import CmuxNextHistory

/// Crash program: the cmux:// page addresses are literals that must parse.
@MainActor @Suite struct PageAddressCrashLiteralTests {
    @Test func pageAddressesParse() {
        #expect(HistoryPageAddress.url.absoluteString == HistoryPageAddress.string)
    }
}
