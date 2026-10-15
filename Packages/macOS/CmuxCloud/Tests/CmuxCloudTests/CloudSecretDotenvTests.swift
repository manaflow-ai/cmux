@testable import CmuxCloud
import Foundation
import Testing

/// `.env` parsing, matching `cmux vm env set --file`.
@Suite struct CloudSecretDotenvTests {
    func pairs(_ text: String) throws -> [String] {
        try CloudSecretDotenv.parse(text).map { "\($0.name)=\($0.value)" }
    }

    @Test
    func parsesTheCommonSubset() throws {
        let text = """
        # comment
        
        ANTHROPIC_API_KEY=sk-ant-1
        export OPENAI_API_KEY=sk-2
        export\tTAB_EXPORT=t
          SPACED = padded  
        DOUBLE="quoted value"
        SINGLE='single # not a comment'
        TRAILING=value # comment
        QUOTED_TRAILING="v" # comment
        HASH=abc#def
        EQUALS=a=b=c
        EMPTY=
        ESCAPED="a\\"b"
        SINGLE_BACKSLASH='a\\'
        """
        #expect(try pairs(text) == [
            "ANTHROPIC_API_KEY=sk-ant-1",
            "OPENAI_API_KEY=sk-2",
            "TAB_EXPORT=t",
            "SPACED=padded",
            "DOUBLE=quoted value",
            "SINGLE=single # not a comment",
            "TRAILING=value",
            "QUOTED_TRAILING=v",
            "HASH=abc#def",
            "EQUALS=a=b=c",
            "EMPTY=",
            // An escaped quote inside double quotes is the quote; single quotes
            // have no escapes, so a backslash before the closing one is literal.
            "ESCAPED=a\"b",
            "SINGLE_BACKSLASH=a\\"
        ])
    }

    @Test
    func textAfterAClosingQuoteSkipsTheLine() {
        // Neither the quoted part nor the whole raw text is what the user meant.
        #expect(throws: CloudSecretDotenvError.self) { try CloudSecretDotenv.parse(#"A="a" junk"#) }
        let result = CloudSecretDotenv.parseLenient("A=\"a\" junk\nB='b'c\nC=\"c\" # comment\n")
        #expect(result.inputs.map { "\($0.name)=\($0.value)" } == ["C=c"])
        #expect(result.skipped.map(\.line) == [1, 2])
        #expect(result.skipped.map(\.name) == ["A", "B"])
    }

    @Test
    func repeatedKeyKeepsLastValueAtFirstPosition() throws {
        #expect(try pairs("A=1\nB=2\nA=3\n") == ["A=3", "B=2"])
    }

    @Test
    func handlesCRLFAndByteOrderMark() throws {
        #expect(try pairs("\u{FEFF}A=1\r\nB=2\r\n") == ["A=1", "B=2"])
        // Line numbers count CRLF lines once.
        #expect(throws: CloudSecretDotenvError(line: 3, reason: .expectedAssignment)) {
            try CloudSecretDotenv.parse("A=1\r\n\r\nnot an assignment\r\n")
        }
    }

    @Test
    func errorsCarryOneBasedLineNumbers() {
        #expect(throws: CloudSecretDotenvError(line: 2, reason: .expectedAssignment)) {
            try CloudSecretDotenv.parse("A=1\nJUST_A_NAME\n")
        }
        #expect(throws: CloudSecretDotenvError(line: 3, reason: .invalidName("1BAD"))) {
            try CloudSecretDotenv.parse("# header\nA=1\n1BAD=x\n")
        }
        #expect(throws: CloudSecretDotenvError(line: 1, reason: .invalidName("A-B"))) {
            try CloudSecretDotenv.parse("A-B=x")
        }
    }

    @Test
    func rejectsMultilineQuotedValues() {
        let text = """
        A=1
        CERT="-----BEGIN
        body
        -----END"
        """
        #expect(throws: CloudSecretDotenvError(line: 2, reason: .multilineValue("CERT"))) {
            try CloudSecretDotenv.parse(text)
        }
        #expect(throws: CloudSecretDotenvError(line: 1, reason: .multilineValue("K"))) {
            try CloudSecretDotenv.parse("K='unterminated")
        }
    }

    @Test
    func errorDescriptionsNeverContainValues() {
        do {
            _ = try CloudSecretDotenv.parse("TOKEN=\"sk-secret-value")
            Issue.record("expected an error")
        } catch {
            let text = error.localizedDescription
            #expect(!text.contains("sk-secret-value"))
            #expect(text.contains("TOKEN"))
            #expect(text.contains("1"))
        }
    }

    @Test
    func emptyTextParsesToNothing() throws {
        #expect(try CloudSecretDotenv.parse("").isEmpty)
        #expect(try CloudSecretDotenv.parse("\n# only comments\n\n").isEmpty)
    }
    // MARK: Lenient

    @Test
    func lenientKeepsGoodLinesAndReportsEachBadOneByLine() {
        let text = """
        # keys
        ANTHROPIC_API_KEY=sk-ant-1
        sk-bare-token-line
        1BAD=sk-under-a-bad-name
        EMPTY=
        OPENAI_API_KEY='sk-2'
        CERT="-----BEGIN
        """
        let result = CloudSecretDotenv.parseLenient(text)
        #expect(result.inputs.map { "\($0.name)=\($0.value)" } == ["ANTHROPIC_API_KEY=sk-ant-1", "OPENAI_API_KEY=sk-2"])
        #expect(result.skipped == [
            CloudSecretDotenvError(line: 3, reason: .expectedAssignment),
            CloudSecretDotenvError(line: 4, reason: .invalidName("1BAD")),
            CloudSecretDotenvError(line: 5, reason: .emptyValue("EMPTY")),
            CloudSecretDotenvError(line: 7, reason: .multilineValue("CERT")),
        ])
    }

    @Test
    func lenientSkipDescriptionsNeverShowLineText() {
        // A bare token, and text before `=` that is not a name: both may be values.
        let result = CloudSecretDotenv.parseLenient("sk-bare-token-line\nsk-under=a-bad-name\n9TOKEN=x\n")
        #expect(result.inputs.isEmpty)
        #expect(result.skipped.map(\.line) == [1, 2, 3])
        for skip in result.skipped {
            #expect(!skip.skipReason.contains("sk-"))
            #expect(!skip.skipReason.contains("9TOKEN"))
            #expect(skip.name == nil)
        }
        #expect(result.skipped.first?.skipReason == "not NAME=value")
    }

    @Test
    func lenientEmptyValueKeepsAnEarlierValue() {
        let result = CloudSecretDotenv.parseLenient("A=1\nA=\n")
        #expect(result.inputs.map { "\($0.name)=\($0.value)" } == ["A=1"])
        #expect(result.skipped == [CloudSecretDotenvError(line: 2, reason: .emptyValue("A"))])
        #expect(result.skipped.first?.name == "A")
    }

    @Test
    func strictParseStillStopsAtTheFirstBadLineAndKeepsEmptyValues() throws {
        #expect(throws: CloudSecretDotenvError(line: 2, reason: .expectedAssignment)) {
            try CloudSecretDotenv.parse("A=1\nbad\nalso bad\n")
        }
        #expect(try pairs("EMPTY=") == ["EMPTY="])
    }
}
