import Foundation
import Testing
@testable import MessagesLabHome

/// `LongTextStore` found a text's index by its print (length and hashes of the first and last KiB), so an
/// edit in the middle that keeps the length (a typo fixed in a long message) drew the old text: the
/// measurement of one text drawn for another. Found by HomeMarkdownRenderFuzzTests;
/// the vendored LongText.swift now compares the bytes on a print hit (cmux patch).
@MainActor @Suite(.serialized) struct LongTextSameLengthEditTests {
    static func texts() -> (original: String, edited: String) {
        let original = (0..<400).map { "line \($0) of a long message with some words in it" }.joined(separator: "\n")
        var bytes = Array(original.utf8)
        let middle = bytes.count / 2
        bytes[middle] = bytes[middle] == UInt8(ascii: "x") ? UInt8(ascii: "y") : UInt8(ascii: "x")
        return (original, String(decoding: bytes, as: UTF8.self))
    }

    @Test func aSameLengthEditInTheMiddleGetsItsOwnLayout() {
        let store = LongTextStore()
        let (original, edited) = Self.texts()
        #expect(LongText.isLong(original))
        #expect(edited.utf8.count == original.utf8.count)
        _ = store.layout(original, width: 760)
        let l = store.layout(edited, width: 760)
        #expect(l.index.text.utf8.elementsEqual(edited.utf8))
        #expect(store.lineage(edited) != store.lineage(original))
    }

    /// The same text in another `String` (no shared storage) still finds its index by its print.
    @Test func theSameTextInAnotherStringKeepsItsIndex() {
        let store = LongTextStore()
        let (original, _) = Self.texts()
        let copy = String(decoding: Array(original.utf8), as: UTF8.self)
        let first = store.layout(original, width: 760)
        #expect(store.layout(copy, width: 760) === first)
    }
}
