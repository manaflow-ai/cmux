import CMUXAgentLaunch
import Testing

@Suite("NushellTypedShellCommand")
struct NushellTypedShellCommandTests {
    @Test("Wraps a POSIX one-liner for nushell via /bin/sh")
    func wrapsPosixCommand() {
        let posix = "cd -- '/tmp/p' 2>/dev/null || [ ! -d '/tmp/p' ] && 'claude' '--resume' 'SID'"
        #expect(
            NushellTypedShellCommand().wrapping(posixCommand: posix)
                == #"^/bin/sh -c "cd -- '/tmp/p' 2>/dev/null || [ ! -d '/tmp/p' ] && 'claude' '--resume' 'SID'""#
        )
    }

    @Test("Escapes double quotes and backslashes, backslashes first")
    func escapesQuotesAndBackslashes() {
        #expect(
            NushellTypedShellCommand().doubleQuoted(#"say "hi" \ bye"#)
                == #""say \"hi\" \\ bye""#
        )
        // A pre-escaped sequence must not collapse: \" becomes \\\" so no
        // invalid nushell escape can be formed.
        #expect(
            NushellTypedShellCommand().doubleQuoted(#"\""#) == #""\\\"""#
        )
    }

    @Test("POSIX printf substitutions ride through untouched")
    func printfSubstitutionSurvives() {
        let posix = #"'claude' "$(printf '\303\251')""#
        #expect(
            NushellTypedShellCommand().wrapping(posixCommand: posix)
                == #"^/bin/sh -c "'claude' \"$(printf '\\303\\251')\"""#
        )
    }

    @Test("Empty command still renders a valid wrapper")
    func emptyCommand() {
        #expect(NushellTypedShellCommand().wrapping(posixCommand: "") == #"^/bin/sh -c """#)
    }
}
