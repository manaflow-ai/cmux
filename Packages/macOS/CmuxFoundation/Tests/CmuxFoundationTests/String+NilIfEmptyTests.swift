import Testing

@testable import CmuxFoundation

@Suite struct StringNilIfEmptyTests {
    @Test func emptyStringBecomesNil() {
        #expect("".nilIfEmpty == nil)
    }

    @Test func nonEmptyStringPassesThrough() {
        #expect("cmux".nilIfEmpty == "cmux")
    }

    @Test func whitespaceIsNotEmpty() {
        // nilIfEmpty only checks isEmpty; a space is non-empty and passes through.
        #expect(" ".nilIfEmpty == " ")
    }
}
