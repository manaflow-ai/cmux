import Testing
@testable import CmuxFoundation

@Suite("POSIX shell words")
struct POSIXShellWordTests {
    @Test("Plain words stay bare", arguments: ["host", "alice@example.test", "/tmp/a_b-c.d", "K=V,x:y+z%"])
    func plainWordsStayBare(_ value: String) {
        #expect(POSIXShellWord.quoted(value) == value)
    }

    @Test("Line terminators are quoted wherever they appear", arguments: [
        "host\n", "host\r", "host\r\n", "ho\nst", "\nhost",
    ])
    func lineTerminatorsAreQuoted(_ value: String) {
        #expect(!POSIXShellWord.isBare(value))
        #expect(POSIXShellWord.quoted(value) == "'" + value + "'")
    }

    @Test("Empty strings and shell metacharacters are quoted")
    func emptyAndMetacharactersAreQuoted() {
        #expect(POSIXShellWord.quoted("") == "''")
        #expect(POSIXShellWord.quoted("a b") == "'a b'")
        #expect(POSIXShellWord.quoted("$(id)") == "'$(id)'")
        #expect(POSIXShellWord.quoted("host;true") == "'host;true'")
        #expect(POSIXShellWord.quoted("it's") == #"'it'"'"'s'"#)
    }

    @Test("Non-ASCII letters are quoted")
    func nonASCIIIsQuoted() {
        #expect(!POSIXShellWord.isBare("hôst"))
        #expect(!POSIXShellWord.isBare("host\u{2028}"))
    }

    @Test("A narrower punctuation set is honored")
    func customPunctuation() {
        #expect(POSIXShellWord.isBare("a,b", punctuation: "_./:@%+=,-"))
        #expect(!POSIXShellWord.isBare("a,b", punctuation: "_./:=@%+-"))
        #expect(!POSIXShellWord.isBare("a\n", punctuation: "_./:=@%+-"))
    }

    @Test("Option-like SSH destinations are detected")
    func optionLikeDestinations() {
        #expect(SSHDestinationArgument.isOptionLike("-oProxyCommand=x"))
        #expect(SSHDestinationArgument.isOptionLike("  -p22"))
        #expect(!SSHDestinationArgument.isOptionLike("alice@host-1"))
        #expect(!SSHDestinationArgument.isOptionLike("host"))
    }

    @Test("Background forwarding overrides turn forwarding off")
    func backgroundForwardingOverrides() {
        #expect(SSHBackgroundForwardingOptions.agentAndX11Off == ["-o", "ForwardAgent=no", "-o", "ForwardX11=no"])
        #expect(SSHBackgroundForwardingOptions.allOff.suffix(2) == ["-o", "ClearAllForwardings=yes"])
        #expect(!SSHBackgroundForwardingOptions.agentAndX11Off.contains("ClearAllForwardings=yes"))
    }
}
