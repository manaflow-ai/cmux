import Testing
import CmuxWorkspaceEnvironment

@Suite("Workspace environment editor format")
struct WorkspaceEnvironmentParserTests {
    @Test("round-trips comment-like keys, multiline values, equals signs, and backslashes")
    func roundTripsAllStructuralCharacters() throws {
        let environment = [
            "#COMMENT": "first\nsecond\rthird\\tail",
            "EMPTY": "",
            "URL": "https://example.test?a=b",
            "PATH": "/tmp/one:/tmp/two",
        ]

        let document = WorkspaceEnvironmentDocument(environment: environment)
        let serialized = document.serialized

        #expect(serialized.contains("\\#COMMENT="))
        #expect(serialized.contains("first\\nsecond\\rthird\\\\tail"))
        #expect(try WorkspaceEnvironmentParser.parse(serialized) == environment)
        #expect(WorkspaceEnvironmentParser.serialize(environment) == serialized)
    }

    @Test("ignores comments and accepts all supported line endings")
    func parsesCommentsAndLineEndings() throws {
        let text = "# ignored\r\nFOO=one=two\rBAR=value\n"
        #expect(try WorkspaceEnvironmentParser().parse(text) == [
            "FOO": "one=two",
            "BAR": "value",
        ])
    }

    @Test("sanitization preserves empty values and drops unsafe ones")
    func sanitizesAtTheInputBoundary() {
        #expect(WorkspaceEnvironmentDocument.sanitized([
            "#COMMENT": "line\none",
            " NUL\u{0}KEY": "ignored",
            "EMPTY": "",
            "GOOD": "value",
        ]) == [
            "#COMMENT": "line\none",
            "EMPTY": "",
            "GOOD": "value",
        ])
    }

    @Test("rejects keys that collide after boundary trimming")
    func rejectsNormalizedKeyCollisions() {
        #expect(WorkspaceEnvironmentDocument.sanitized([
            " FOO ": "spaced",
            "FOO": "canonical",
            "GOOD": "value",
        ]) == [
            "GOOD": "value",
        ])
    }

    @Test("reports decoded malformed entries with source line numbers")
    func reportsParseErrors() {
        do {
            _ = try WorkspaceEnvironmentParser.parse("GOOD=value\nBROKEN\n")
            Issue.record("Expected an invalid assignment")
        } catch let error as WorkspaceEnvironmentParser.ParseError {
            #expect(error == .invalidAssignment(line: 2))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            _ = try WorkspaceEnvironmentParser.parse("\\#DUP=one\n# comment\n\\#DUP=two\n")
            Issue.record("Expected a duplicate key")
        } catch let error as WorkspaceEnvironmentParser.ParseError {
            #expect(error == .duplicateKey(line: 3))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
