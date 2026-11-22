import CmuxMobileDesign
import Testing
@testable import CmuxMobileOnboarding

/// TestFlight, Nov 5: the emailed sign-in code was `FWT88N`, but the code boxes
/// showed a number pad and dropped every letter, so nobody with a letter in their
/// code could sign in. The field must take the codes Stack Auth sends.
@Suite struct EmailCodeEntryTests {
    let entry = EmailCodeEntry()

    @Test func takesTheLettersInAnEmailedCode() {
        #expect(entry.normalized("FWT88N") == "FWT88N")
        #expect(entry.isComplete(entry.normalized("FWT88N")))
    }

    @Test func showsAKeyboardWithLetters() {
        #expect(entry.characters.hasLetters)
    }

    @Test(arguments: [
        ("fwt88n", "FWT88N"),      // typed lowercase, autocapitalization off
        ("FWT 88N", "FWT88N"),     // pasted with a space
        ("fwt-88n", "FWT88N"),     // pasted with a dash
        (" FWT88N\n", "FWT88N"),   // pasted with whitespace around it
        ("FWT88N7", "FWT88N"),     // one more key after the code is full
        ("Your code is FWT88N", "FWT88N"), // a whole pasted sentence
    ])
    func normalizesPastedAndTypedCodes(raw: String, expected: String) {
        #expect(entry.normalized(raw) == expected)
    }

    @Test func dropsNonASCIILettersInsteadOfExpandingThem() {
        // "ß".uppercased() is "SS"; uppercasing before filtering would add letters.
        #expect(entry.normalized("ßé12") == "12")
    }

    @Test func digitOnlyCodesStillWork() {
        #expect(entry.normalized("424242") == "424242")
        #expect(CodeEntryCharacters.digits.normalized("4a2b4c", length: 6) == "424")
        #expect(!CodeEntryCharacters.digits.hasLetters)
    }
}
