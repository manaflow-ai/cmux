import Testing
@testable import CmuxFoundation

@Suite("POSIX shell words")
struct POSIXShellWordTests {
    @Test("Plain words stay bare", arguments: ["host", "alice@example.test", "/tmp/a_b-c.d", "K=V,x:y+z%"])
    func plainWordsStayBare(_ value: String) {
        #expect(value.posixShellWord == value)
    }

    @Test("Line terminators are quoted wherever they appear", arguments: [
        "host\n", "host\r", "host\r\n", "ho\nst", "\nhost",
    ])
    func lineTerminatorsAreQuoted(_ value: String) {
        #expect(!value.isPOSIXShellBareWord())
        #expect(value.posixShellWord == "'" + value + "'")
    }

    @Test("Empty strings and shell metacharacters are quoted")
    func emptyAndMetacharactersAreQuoted() {
        #expect("".posixShellWord == "''")
        #expect("a b".posixShellWord == "'a b'")
        #expect("$(id)".posixShellWord == "'$(id)'")
        #expect("host;true".posixShellWord == "'host;true'")
        #expect("it's".posixShellWord == #"'it'"'"'s'"#)
    }

    @Test("Non-ASCII letters are quoted")
    func nonASCIIIsQuoted() {
        #expect(!"hôst".isPOSIXShellBareWord())
        #expect(!"host\u{2028}".isPOSIXShellBareWord())
    }

    @Test("A narrower punctuation set is honored")
    func customPunctuation() {
        #expect("a,b".isPOSIXShellBareWord(punctuation: "_./:@%+=,-"))
        #expect(!"a,b".isPOSIXShellBareWord(punctuation: "_./:=@%+-"))
        #expect(!"a\n".isPOSIXShellBareWord(punctuation: "_./:=@%+-"))
    }
}
