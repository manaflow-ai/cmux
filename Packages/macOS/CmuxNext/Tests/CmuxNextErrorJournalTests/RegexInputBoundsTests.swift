import CmuxFuzzSupport
import Foundation
import Testing
@testable import CmuxNextErrorJournal

/// p10-stability-191: the journal's text passes (redaction, templates, crash and log parsing) find
/// what their former regexes found, and stay linear on text built to make a backtracking matcher
/// rescan.
@Suite struct RegexInputBoundsTests {
    let redactor = ErrorRedactor()

    // MARK: - Assignment anchors

    @Test func anchorsStartWhereTheWordBoundaryWas() {
        let units = Array("x my-token: abc 9-token=v".utf16)
        let anchors = ErrorRedactor.assignmentAnchors(in: units)
        let keys = anchors.map { String(decoding: units[$0.key.location..<NSMaxRange($0.key)], as: UTF16.self) }
        // `my-token` from its start; after a digit `\b` is first at `token` (the `-` before it).
        #expect(keys == ["my-token", "token"])
        #expect(anchors.map { $0.end } == [12, 24])
    }

    @Test func anchorsTakeQuotesBackslashesAndSpacesAroundTheSeparator() {
        let units = Array(#"a\"  :  b c"=d e\ =f"#.utf16)
        let anchors = ErrorRedactor.assignmentAnchors(in: units)
        #expect(anchors.map { $0.key } == [NSRange(location: 0, length: 1), NSRange(location: 10, length: 1)])
        // `e\ =` has backslashes with no quote after them: not a separator.
        #expect(anchors.map { $0.end } == [8, 13])
    }

    @Test func aRunWithNoSeparatorAfterItGivesNoAnchor() {
        let units = Array(String(repeating: "a-", count: 4000).utf16)
        #expect(ErrorRedactor.assignmentAnchors(in: units).isEmpty)
    }

    @Test func aKeyAfterALetterOutsideASCIIIsNotAnAnchor() {
        // `é` is a word character, so `\b` is not between it and `token`.
        #expect(ErrorRedactor.assignmentAnchors(in: Array("étoken=x".utf16)).isEmpty)
    }

    // MARK: - Query keys

    @Test func queryKeysAreOnePerPositionTheLookaheadMatched() {
        let units = Array("a=1&b(c=2 d".utf16)
        // `a` at the start; `b(c` after `&`; `c` after `(`.
        #expect(ErrorRedactor.queryKeys(in: units) == [
            NSRange(location: 0, length: 1), NSRange(location: 4, length: 3), NSRange(location: 6, length: 1),
        ])
    }

    @Test func overlappingQueryKeysRedactTheirValueOnce() {
        #expect(redactor.redact("x(apikey=sekret&page=2") == "x(apikey=<redacted>&page=2")
        #expect(redactor.redact("a(b(token=sekret") == "a(b(token=<redacted>")
        let hostile = String(repeating: "(", count: 5000) + "=v"
        #expect(redactor.redact(hostile) == hostile)
    }

    @Test func aShorterKeyOfAGroupIsReadWithoutItsPunctuation() {
        // Only the shorter key `apikey.….` is sensitive (an exact name); the longest `x(apikey.….` is not.
        let dots = String(repeating: ".", count: 100)
        #expect(redactor.redact("x(apikey\(dots)=sekret") == "x(apikey\(dots)=<redacted>")
        #expect(redactor.redact(String(repeating: "a(", count: 3000) + "apikey=sekret").hasSuffix("apikey=<redacted>"))
        // A bad escape fails the longest key's decode; its words still count, decoded where they can be.
        #expect(redactor.redact("%zz(%74oken" + dots + "a=sekret") == "%zz(%74oken" + dots + "a=<redacted>")
    }

    // MARK: - Redactor rules

    @Test func secretsAreStillRedacted() {
        #expect(redactor.redact("my-token: abc&x=1") == "my-token: <redacted>&x=1")
        #expect(redactor.redact("see https://u:p@host/x") == "see https://<redacted>@host/x")
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        #expect(redactor.redact("x-\(jwt) y") == "x-<jwt> y")
    }

    @Test func aLongValueRunOfSpacesEndsAtTheNextKey() {
        let spaces = String(repeating: " ", count: 5000)
        #expect(redactor.redact("password=a\(spaces)user=b") == "password=<redacted>\(spaces)user=b")
        #expect(redactor.redact("password=a\(spaces)b") == "password=<redacted>")
    }

    @Test func aTextPastTheCapIsCutAtWhiteSpace() {
        let head = String(repeating: "abcd ", count: ErrorRedactor.maxInputScalars / 5)
        let output = redactor.redact(head + String(repeating: "z", count: 100))
        #expect(output == head.dropLast() + "…")
        #expect(redactor.redact("short text") == "short text")
    }

    // MARK: - Templates

    @Test func templatesKeepTheirShapeOnTheRewrittenRules() {
        let normalizer = ErrorNormalizer()
        #expect(normalizer.template("got Xhttp://h/p and deadbeef1 and 12ab") == "got X<url> and <id> and <id>")
        #expect(normalizer.template("word abcdef and 0123") == "word abcdef and <n>")
        #expect(normalizer.template(String(repeating: "a", count: 3000)).hasSuffix("…"))
    }

    @Test func aMessagePastTheCapIsReadToTheCap() {
        let message = String(repeating: "é", count: ErrorNormalizer.maxInputUTF16 + 10)
        #expect(message.utf16Prefix(ErrorNormalizer.maxInputUTF16).utf16.count == ErrorNormalizer.maxInputUTF16)
        #expect("a😀b".utf16Prefix(2) == "a")
    }

    // MARK: - Crash reports and logs

    @Test func theExceptionTypeIsTheLastOneBeforeTheObjectsEnd() {
        #expect(CrashReportErrorSource.exceptionType(in: #"{"exception" : {"type":"A","x":"type","type" : "B"},"type":"C"}"#) == "B")
        #expect(CrashReportErrorSource.exceptionType(in: #""exception":{"codes":"1"},"exception":{"type":"D"}"#) == "D")
        #expect(CrashReportErrorSource.exceptionType(in: #""exception":{"codes":"1"},"type":"E""#) == nil)
        // A value may run past the `}` (as the pattern's did); the key may not.
        #expect(CrashReportErrorSource.exceptionType(in: #""exception":{"type":"F}G""#) == "F}G")
        #expect(CrashReportErrorSource.exceptionType(in: #""exception":{"type"type":"H""#) == "H")
    }

    @Test func manyExceptionKeysWithNoObjectEndGiveNothing() {
        let text = String(repeating: #""exception":{"#, count: 4000)
        #expect(CrashReportErrorSource.exceptionType(in: text) == nil)
    }

    @Test func aPanicLineStillParses() {
        let events = LogLineParser(source: "acpmux", file: "a.log")
            .events(in: "thread 'x' panicked at src/a.rs:12:5: boom\nthread 'y' panicked at b.rs:\(String(repeating: "9", count: 3000))x\ry\n")
        #expect(events.first?.message == "panic: boom")
        #expect(events.first?.topFrame == "src/a.rs:12")
        #expect(events.count == 1)
    }
}

/// The time each pass takes on 64 KiB built to make it rescan: under 50 ms, on every timed attempt.
/// The former patterns took seconds on these inputs. Timing is not a CI check (Lawrence
/// 2026-10-23): it runs with `CMUX_REGEX_BUDGET_FUZZ=1`, which agents set on the fleet:
///
/// ```
/// CMUX_REGEX_BUDGET_FUZZ=1 swift test -c release --filter RegexInputBudgetTests
/// ```
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CMUX_REGEX_BUDGET_FUZZ"] == "1",
                "set CMUX_REGEX_BUDGET_FUZZ=1; agents run it on the fleet (Lawrence 2026-10-23)"))
struct RegexInputBudgetTests {
    static let bytes = 64 << 10
    static let budget = FuzzBudget(perUnit: .milliseconds(50), unitBytes: bytes)

    static func repeated(_ piece: String) -> String {
        FuzzText.truncated(String(repeating: piece, count: bytes / piece.utf8.count + 1), toBytes: bytes)
    }

    static let redactorPieces = ["a-", "a", "(", " ", "token= ", "eyJ-", "https", "\\\"", "sk-", "key=a ", "x(apikey"]
    static let normalizerPieces = ["a", "1a", "0", "\"", "/Users/", "~", "\u{1b}[1", "a_"]

    @Test func theRedactorIsLinear() throws {
        let redactor = ErrorRedactor()
        for piece in Self.redactorPieces {
            let text = Self.repeated(piece)
            try Self.budget.check("ErrorRedactor.redact of \(piece.debugDescription) repeated", bytes: text.utf8.count) { _ in
                _ = redactor.redact(text)
            }
        }
    }

    @Test func theNormalizerIsLinear() throws {
        let normalizer = ErrorNormalizer()
        for piece in Self.normalizerPieces {
            let text = Self.repeated(piece)
            try Self.budget.check("ErrorNormalizer.template of \(piece.debugDescription) repeated", bytes: text.utf8.count) { _ in
                _ = normalizer.template(text)
            }
        }
    }

    @Test func crashAndLogParsingIsLinear() throws {
        let reports = [Self.repeated(#""exception":{"#), Self.repeated(#""exception":{"type"x"#)]
        for report in reports {
            try Self.budget.check("CrashReportErrorSource.exceptionType", bytes: report.utf8.count) { _ in
                _ = CrashReportErrorSource.exceptionType(in: report)
            }
        }
        let line = "panicked at a.rs:" + Self.repeated("9") + "x\ry"
        try Self.budget.check("LogLineParser.events", bytes: line.utf8.count) { _ in
            _ = LogLineParser(source: "s", file: "f").events(in: line)
        }
    }
}
