import Foundation
import Testing
@testable import CmuxControlSocket

@Suite("ControlNotificationFieldFormatter")
struct ControlNotificationFieldFormatterTests {
    private let formatter = ControlNotificationFieldFormatter()

    @Test("created_at renders ISO-8601 internet date-time in GMT")
    func createdAtISO8601IsGMTInternetDateTime() {
        // 2021-01-01T00:00:00Z = 1609459200 seconds since epoch.
        let date = Date(timeIntervalSince1970: 1_609_459_200)
        #expect(formatter.createdAtISO8601(date) == "2021-01-01T00:00:00Z")
    }

    @Test("created_at matches a freshly-built reference formatter byte-for-byte")
    func createdAtMatchesReferenceFormatter() {
        let reference = ISO8601DateFormatter()
        reference.formatOptions = [.withInternetDateTime]
        reference.timeZone = TimeZone(secondsFromGMT: 0)
        let date = Date(timeIntervalSince1970: 1_700_000_123)
        #expect(formatter.createdAtISO8601(date) == reference.string(from: date))
    }

    @Test("trailing field prefixes pct: and leaves plain text untouched")
    func trailingFieldPlainText() {
        #expect(formatter.listTrailingField("My Tab") == "pct:My Tab")
        #expect(formatter.listTrailingField("") == "pct:")
    }

    @Test("trailing field escapes percent before the delimiter and line breaks")
    func trailingFieldEscapesInOrder() {
        // `%` must escape first so the escape sequences it introduces are not
        // re-escaped: a raw `|` becomes `%7C`, not `%257C`.
        #expect(formatter.listTrailingField("a|b") == "pct:a%7Cb")
        #expect(formatter.listTrailingField("50%") == "pct:50%25")
        #expect(formatter.listTrailingField("x\ny\rz") == "pct:x%0Ay%0Dz")
        #expect(formatter.listTrailingField("%|") == "pct:%25%7C")
    }
}
