import Testing
@testable import CmuxHomeCore

@Suite struct ContactAddressTests {
    @Test func emailsNormalizeToLowercase() {
        #expect(ContactAddress.parse("  Austin@Manaflow.com ") == .email("austin@manaflow.com"))
    }

    @Test(arguments: ["a@b", "@x.com", "a@.com", "a@x..com", "a b@x.com", "a@x.c0m", ".a@x.com"])
    func invalidEmailsAreRefused(_ text: String) {
        #expect(ContactAddress.parse(text) == nil)
    }

    @Test func usNumbersGainTheCountryCode() {
        #expect(ContactAddress.parse("(415) 555-0134") == .phone("+14155550134"))
        #expect(ContactAddress.parse("1 415 555 0134") == .phone("+14155550134"))
        #expect(ContactAddress.parse("+44 20 7946 0958") == .phone("+442079460958"))
        #expect(ContactAddress.parse("0044 20 7946 0958") == .phone("+442079460958"))
    }

    @Test(arguments: ["555-0134", "+1 415 555", "415-555-0134x9", "4+15", "hello"])
    func invalidPhonesAreRefused(_ text: String) {
        #expect(ContactAddress.parse(text) == nil)
    }

    @Test func fieldSplitsDedupesAndReportsInvalidTokens() {
        let parse = ContactFieldParse.parse("a@x.com, A@x.com; (415) 555-0134, nope")
        #expect(parse.addresses == [.email("a@x.com"), .phone("+14155550134")])
        #expect(parse.invalid == ["nope"])
    }
}
