import Testing

import CmuxFoundation

@Suite struct StringJavaScriptStringLiteralTests {
    @Test func plainStringIsQuoted() {
        #expect("hello".javaScriptStringLiteral == "\"hello\"")
    }

    @Test func emptyStringIsEmptyQuotes() {
        #expect("".javaScriptStringLiteral == "\"\"")
    }

    @Test func escapesDoubleQuotesAndBackslashes() {
        #expect(#"a"b\c"#.javaScriptStringLiteral == #""a\"b\\c""#)
    }

    @Test func escapesNewlines() {
        #expect("line1\nline2".javaScriptStringLiteral == #""line1\nline2""#)
    }

    @Test func preservesUnicode() {
        #expect("café".javaScriptStringLiteral == "\"café\"")
    }
}
