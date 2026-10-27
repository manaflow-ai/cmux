@testable import CmuxNextErrorJournal
import Foundation
import Testing

/// p10-stability-170: the redactor's scans read UTF-16 units through CmuxNextCompat's checked helpers, so a
/// value that runs to the end of the text (an open quote, a run of backslashes, an empty value) ends the scan
/// there instead of reading past it.
struct ErrorRedactorBoundaryTests {
    private let redactor = ErrorRedactor()

    /// Texts whose secret value reaches the end of the text; each is also cut after every character.
    private static let endings = [
        #"password="hunter2"#,
        #"password=\\\"hunter2"#,
        #"secret='a\'b"#,
        #"token: abc  api_key = def"#,
        "https://x.test/p?token=abc&code=",
        "session_key=😀value",
    ]

    @Test func everyPrefixRedactsWithoutReadingPastTheEnd() {
        for text in Self.endings {
            for count in 0...text.count {
                let prefix = String(text.prefix(count))
                // "<redacted>" alone is the fail-closed answer for a value range outside the text.
                #expect(redactor.redact(prefix) != "<redacted>", "\(prefix)")
            }
        }
    }

    @Test func valuesThatRunToTheEndAreRedacted() {
        #expect(!redactor.redact(#"password="hunter2"#).contains("hunter2"))
        #expect(!redactor.redact(#"secret='a\'b"#).contains(#"a\'b"#))
        #expect(!redactor.redact("https://x.test/p?token=abc").contains("abc"))
        #expect(redactor.redact("password=") == "password=<redacted>")
        #expect(redactor.redact("note: nothing secret") == "note: nothing secret")
    }
}
