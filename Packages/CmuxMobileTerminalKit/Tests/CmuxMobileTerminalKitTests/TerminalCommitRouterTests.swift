import Foundation
import Testing
@testable import CmuxMobileTerminalKit

@Suite("TerminalCommitRouter input-vs-paste classification")
struct TerminalCommitRouterTests {
    @Test("a single character is per-character input")
    func singleCharacterIsInput() {
        #expect(TerminalCommitRouter.route(for: "a") == .input)
    }

    @Test("Return (a single character) stays input so CR semantics are preserved")
    func returnIsInput() {
        #expect(TerminalCommitRouter.route(for: "\n") == .input)
    }

    @Test("the empty string routes to input (no-op send)")
    func emptyIsInput() {
        #expect(TerminalCommitRouter.route(for: "") == .input)
    }

    @Test("a multi-character word is a paste")
    func wordIsPaste() {
        #expect(TerminalCommitRouter.route(for: "hello") == .paste)
    }

    @Test("a dictated multi-line block is a paste so it is not CR-fragmented")
    func multilineBlockIsPaste() {
        #expect(TerminalCommitRouter.route(for: "line one\nline two") == .paste)
    }

    @Test("a single emoji grapheme cluster is one character, so input")
    func singleEmojiIsInput() {
        // A flag emoji is multiple scalars but one Character, so it must not be
        // mis-classified as a multi-character paste.
        #expect(TerminalCommitRouter.route(for: "🇺🇸") == .input)
    }

    @Test("two emoji are a paste")
    func twoEmojiArePaste() {
        #expect(TerminalCommitRouter.route(for: "🇺🇸🇯🇵") == .paste)
    }
}
