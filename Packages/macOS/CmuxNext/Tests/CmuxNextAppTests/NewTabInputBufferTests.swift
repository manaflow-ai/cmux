import Testing
@testable import CmuxNextApp

/// Cmd-T owns printable keys from the action until the New Tab field is ready.
/// The same sequence must survive both a parked spare and a cold page.
@Suite struct NewTabInputBufferTests {
    @Test func aWarmSpareReplaysEveryKeyInOrder() {
        var buffer = NewTabInputBuffer()
        buffer.append("h")
        buffer.append("e")
        buffer.append("l")
        buffer.append("l")
        buffer.append("o")

        #expect(buffer.take() == "hello")
        #expect(buffer.take() == nil)
    }

    @Test func aColdPageUsesTheSameBufferBeforeItsFieldExists() {
        var buffer = NewTabInputBuffer()
        for character in "hello" { buffer.append(String(character)) }

        // No web view or timer is involved: the action owner holds the text
        // until the field reports ready, then hands it over exactly once.
        #expect(buffer.take() == "hello")
    }
}
