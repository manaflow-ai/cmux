import Foundation
import Testing
@testable import CmuxNextBookmarks

/// Crash program: the cmux:// page address is a literal that must parse.
@MainActor @Suite struct BookmarksCrashLiteralTests {
    @Test func pageAddressParses() {
        #expect(BookmarkPageAddress.url.absoluteString == BookmarkPageAddress.string)
    }
}
