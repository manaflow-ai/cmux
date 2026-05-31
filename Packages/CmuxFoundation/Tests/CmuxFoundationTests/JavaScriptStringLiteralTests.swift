import Testing

import CmuxFoundation

@Suite struct JavaScriptStringLiteralTests {
    @Test func nilInputReturnsNil() {
        #expect(cmuxJavaScriptStringLiteral(nil) == nil)
    }

    @Test func plainStringIsQuoted() {
        #expect(cmuxJavaScriptStringLiteral("hello") == "\"hello\"")
    }

    @Test func emptyStringIsEmptyQuotes() {
        #expect(cmuxJavaScriptStringLiteral("") == "\"\"")
    }

    @Test func escapesDoubleQuotesAndBackslashes() {
        #expect(cmuxJavaScriptStringLiteral(#"a"b\c"#) == #""a\"b\\c""#)
    }

    @Test func escapesNewlines() {
        #expect(cmuxJavaScriptStringLiteral("line1\nline2") == #""line1\nline2""#)
    }

    @Test func preservesUnicode() {
        #expect(cmuxJavaScriptStringLiteral("café") == "\"café\"")
    }
}
