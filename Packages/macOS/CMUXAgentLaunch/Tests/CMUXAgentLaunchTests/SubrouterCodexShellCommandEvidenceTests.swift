import Testing
@testable import CMUXAgentLaunch

/// Older cmux snapshots kept only a hook binding whose persisted `command` is a
/// shell string. That string is evidence of which provider the session used,
/// never something to run again: anything that isn't a plain, fully parseable
/// Codex invocation reads as `ambiguous`, which never routes.
@Suite struct SubrouterCodexShellCommandEvidenceTests {
    private let router = SubrouterCodexResumeRouting()

    @Test(arguments: [
        "codex -c model_provider=subrouter",
        "codex -c 'model_provider=subrouter'",
        "codex -c \"model_provider=subrouter\"",
        "codex --config=model_provider=subrouter",
        "/opt/homebrew/bin/codex -c model_provider=subrouter",
        "sr codex -c model_provider=subrouter",
        "codex -c model_provider=subrouter -c model_provider=subrouter",
        "  codex   -c\tmodel_provider=subrouter  ",
        "codex -c model\\_provider=subrouter",
    ])
    func plainCodexInvocationNamingSubrouterIsProven(command: String) {
        #expect(router.providerEvidence(inShellCommand: command) == .provider("subrouter"))
    }

    @Test func plainCodexInvocationWithoutAProviderIsAbsent() {
        #expect(router.providerEvidence(inShellCommand: "codex") == .absent)
        #expect(router.providerEvidence(inShellCommand: "codex resume abc") == .absent)
        #expect(router.providerEvidence(inShellCommand: nil) == .absent)
        #expect(router.providerEvidence(inShellCommand: "   ") == .absent)
    }

    @Test func otherProviderIsReportedAsThatProvider() {
        #expect(router.providerEvidence(inShellCommand: "codex -c model_provider=openai") == .provider("openai"))
    }

    @Test(arguments: [
        // Conflicting providers.
        "codex -c model_provider=subrouter -c model_provider=openai",
        // Shell operators, expansions and substitutions.
        "codex -c model_provider=subrouter; rm -rf ~",
        "codex -c model_provider=subrouter && echo ok",
        "codex -c model_provider=subrouter | tee log",
        "codex -c model_provider=subrouter > out",
        "codex -c model_provider=$PROVIDER",
        "codex -c \"model_provider=$PROVIDER\"",
        "codex -c model_provider=`echo subrouter`",
        "codex -c \"model_provider=`echo subrouter`\"",
        "codex -c model_provider=$(echo subrouter)",
        "(codex -c model_provider=subrouter)",
        "codex -c model_provider=subrouter &",
        // Globs, home expansion, history expansion and comments.
        "codex -c model_provider=sub*",
        "codex -c model_provider=subrouter?",
        "codex -c model_provider=[s]ubrouter",
        "codex -c model_provider={subrouter,openai}",
        "~/bin/codex -c model_provider=subrouter",
        "codex -c model_provider=subrouter!",
        "codex -c model_provider=subrouter # trailing comment",
        // Unterminated quotes and a dangling escape.
        "codex -c 'model_provider=subrouter",
        "codex -c \"model_provider=subrouter",
        "codex -c model_provider=subrouter\\",
        // Line breaks and control characters.
        "codex -c model_provider=subrouter\nrm -rf ~",
        "codex -c model_provider=subrouter\rrm",
        "codex -c model_provider=sub\u{0}router",
        // Not a Codex invocation, or a prefixed one.
        "sh -c 'codex -c model_provider=subrouter'",
        "env codex -c model_provider=subrouter",
        "PROVIDER=x codex -c model_provider=subrouter",
        "cd -- '/tmp/project' && codex -c model_provider=subrouter",
        "evil -c model_provider=subrouter",
        "sr claude proxy",
        // A malformed provider assignment (a stray quote in the value).
        "codex -c \"model_provider='subrouter\"",
    ])
    func anythingNotPlainlyParseableIsAmbiguous(command: String) {
        #expect(router.providerEvidence(inShellCommand: command) == .ambiguous)
    }

    @Test func oversizedCommandIsAmbiguousWithoutParsing() {
        let padding = String(repeating: "a", count: SubrouterCodexResumeRouting.maxShellCommandBytes)
        #expect(router.providerEvidence(inShellCommand: "codex -c model_provider=subrouter \(padding)") == .ambiguous)
    }

    @Test func commandWithTooManyWordsIsAmbiguous() {
        let words = Array(repeating: "x", count: SubrouterCodexResumeRouting.maxShellCommandTokens)
        let command = (["codex", "-c", "model_provider=subrouter"] + words).joined(separator: " ")
        #expect(router.providerEvidence(inShellCommand: command) == .ambiguous)
    }

    @Test func commandAtTheWordLimitStillParses() {
        let words = Array(repeating: "x", count: SubrouterCodexResumeRouting.maxShellCommandTokens - 3)
        let command = (["codex", "-c", "model_provider=subrouter"] + words).joined(separator: " ")
        #expect(router.providerEvidence(inShellCommand: command) == .provider("subrouter"))
    }

    @Test func quotingIsUnwrappedTheWayAPOSIXShellWould() throws {
        // A single-quoted backslash is literal, so this names a different
        // key and records no provider at all.
        #expect(router.providerEvidence(inShellCommand: "codex -c 'model\\_provider=subrouter'") == .absent)
        // Inside double quotes a backslash only escapes ", \, $ and `.
        let doubleQuoted = try #require(SubrouterCodexResumeRouting.shellCommandTokens("\"a\\\"b\" \"c\\d\""))
        #expect(doubleQuoted == ["a\"b", "c\\d"])
        let tokens = try #require(SubrouterCodexResumeRouting.shellCommandTokens("a 'b c' \"d\\\\e\" f\\ g"))
        #expect(tokens == ["a", "b c", "d\\e", "f g"])
    }

    @Test func tokenizerReadsUnicodeScalarsSoACombiningMarkCannotHideAQuote() throws {
        // As Characters, `"` + U+0301 is one grapheme and not a quote; a shell
        // reads the quote. Scalars agree with the shell.
        let tokens = try #require(SubrouterCodexResumeRouting.shellCommandTokens("\"\u{301}x\" y"))
        #expect(tokens == ["\u{301}x", "y"])
        #expect(router.providerEvidence(inShellCommand: "codex -c \"\u{301}\" ; rm") == .ambiguous)
    }

    @Test func embeddedNewlineIsAmbiguous() {
        #expect(router.providerEvidence(inShellCommand: "codex -c model_provider=subrouter\n") == .ambiguous)
        #expect(router.providerEvidence(inShellCommand: "codex\n-c model_provider=subrouter") == .ambiguous)
    }

    @Test func providerAfterTheArgumentTerminatorIsPromptText() {
        #expect(router.providerEvidence(inShellCommand: "codex -- -c model_provider=subrouter") == .absent)
    }
}
