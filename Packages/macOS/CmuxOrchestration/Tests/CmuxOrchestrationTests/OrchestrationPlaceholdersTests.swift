import Foundation
import Testing
@testable import CmuxOrchestration

@Suite struct OrchestrationPlaceholdersTests {
    @Test func scansDistinctPlaceholdersInOrder() {
        let names = OrchestrationPlaceholders.scan("a {{task}} b {{ repo_root }} c {{task}}")
        #expect(names == ["task", "repo_root"])
    }

    @Test func malformedBracesStayLiteral() throws {
        #expect(OrchestrationPlaceholders.scan("{{not closed") == [])
        #expect(OrchestrationPlaceholders.scan("{{Bad Name}}") == [])
        #expect(OrchestrationPlaceholders.scan("{single}") == [])
        #expect(OrchestrationPlaceholders.scan("{{UPPER}}") == [])
        let rendered = try OrchestrationPlaceholders.render("{{not closed", values: [:])
        #expect(rendered == "{{not closed")
    }

    @Test func rendersValues() throws {
        let rendered = try OrchestrationPlaceholders.render(
            "Fix {{task}} in {{ workspace_dir }}",
            values: ["task": "the bug", "workspace_dir": "/tmp/w"]
        )
        #expect(rendered == "Fix the bug in /tmp/w")
    }

    @Test func missingPlaceholderThrowsWithAllMissingNames() {
        do {
            _ = try OrchestrationPlaceholders.render("{{alpha}} {{beta}}", values: [:])
            Issue.record("expected render to throw")
        } catch let error as OrchestrationManifestError {
            #expect(error.message.contains("{{alpha}}"))
            #expect(error.message.contains("{{beta}}"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func adjacentPlaceholdersAndBraces() throws {
        let rendered = try OrchestrationPlaceholders.render(
            "{{a}}{{b}} {ok} {{{a}}}",
            values: ["a": "1", "b": "2"]
        )
        // "{{{a}}}" opens at the second brace: literal "{" + placeholder + "}".
        #expect(rendered == "12 {ok} {1}")
    }

    @Test func shellQuotingEscapesSingleQuotes() {
        #expect(OrchestrationPlaceholders.shellQuoted("plain") == "'plain'")
        #expect(OrchestrationPlaceholders.shellQuoted("it's") == "'it'\\''s'")
        #expect(OrchestrationPlaceholders.shellQuoted("a\nb") == "'a\nb'")
    }

    @Test func slugsSqueezeAndTrim() {
        #expect(OrchestrationPlaceholders.slug("Fix: the Flaky test!!") == "fix-the-flaky-test")
        #expect(OrchestrationPlaceholders.slug("__init__") == "init")
        #expect(OrchestrationPlaceholders.slug("") == "")
        #expect(OrchestrationPlaceholders.slug(String(repeating: "long word ", count: 20)).count <= 40)
        #expect(!OrchestrationPlaceholders.slug("ends with punct...").hasSuffix("-"))
    }
}
