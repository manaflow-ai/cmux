import Testing
@testable import CmuxControlSocket

#if DEBUG
/// Behavior coverage for ``Swift/String/socketTextEscapesDecoded``, the
/// backslash-escape decoder the DEBUG `simulate_type` socket witness uses.
@Suite struct StringSocketTextEscapesTests {
    @Test func decodesKnownControlEscapes() {
        #expect("a\\nb".socketTextEscapesDecoded == "a\nb")
        #expect("a\\rb".socketTextEscapesDecoded == "a\rb")
        #expect("a\\tb".socketTextEscapesDecoded == "a\tb")
    }

    @Test func decodesEscapedBackslash() {
        #expect("a\\\\b".socketTextEscapesDecoded == "a\\b")
    }

    @Test func preservesUnknownEscapeWithBackslash() {
        // `\x` is not a known escape, so the backslash is kept and the
        // character appended unchanged.
        #expect("a\\xb".socketTextEscapesDecoded == "a\\xb")
    }

    @Test func preservesTrailingLoneBackslash() {
        #expect("ab\\".socketTextEscapesDecoded == "ab\\")
    }

    @Test func passesPlainTextThrough() {
        #expect("hello world".socketTextEscapesDecoded == "hello world")
        #expect("".socketTextEscapesDecoded == "")
    }
}
#endif
