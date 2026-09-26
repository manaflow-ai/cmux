import Foundation
import Testing
@testable import CmuxFilePreviewCore

struct ReadOnlyVimNavigationTests {
    @Test func verticalYanksIncludeBothEndpointLines() {
        var vim = ReadOnlyVimNavigation(text: "alpha\nbeta\ngamma\n")
        for key in ["l", "y", "j"] { vim.handle(key) }
        #expect(vim.yankedText == "alpha\nbeta\n")
        #expect(vim.cursor == 1)
        for key in ["j", "y", "k"] { vim.handle(key) }
        #expect(vim.yankedText == "alpha\nbeta\n")
        #expect(vim.cursor == 7)
        for key in ["g", "g", "2", "y", "j"] { vim.handle(key) }
        #expect(vim.yankedText == "alpha\nbeta\ngamma\n")
    }

    @Test func horizontalYankUsesExclusiveMotionAndIncludesEndCharacter() {
        var vim = ReadOnlyVimNavigation(text: "alpha")
        for key in ["y", "l"] { vim.handle(key) }
        #expect(vim.yankedText == "a")
        for key in ["3", "y", "l"] { vim.handle(key) }
        #expect(vim.yankedText == "alp")
        vim.handle("$")
        for key in ["y", "l"] { vim.handle(key) }
        #expect(vim.yankedText == "a")
    }

    @Test(arguments: ["i", "G", "g", "2", "q"])
    func unsupportedYankDoesNotOverwriteClipboard(motion: String) {
        var vim = ReadOnlyVimNavigation(text: "alpha beta")
        vim.handle("y")
        vim.handle(motion)
        #expect(vim.yankedText == nil)
        #expect(vim.cursor == 0)
    }

    @Test func longLineNavigation() {
        let padding = String(repeating: " ", count: 10_000)
        var vim = ReadOnlyVimNavigation(text: padding + "x\n" + padding + "y")
        vim.handle("^")
        #expect(vim.cursor == 10_000)
        vim.handle("j")
        #expect(vim.cursor == 20_002)
        vim.handle("0")
        vim.handle("f")
        vim.handle("y")
        #expect(vim.cursor == 20_002)
    }

    @Test func countsAndWords() {
        var vim = ReadOnlyVimNavigation(text: "one two\nthree four\nfive six\n")
        for key in ["2", "j", "0", "w"] { vim.handle(key) }
        #expect(vim.cursor == 24)
        vim.handle("b")
        #expect(vim.cursor == 19)
        vim.handle("e")
        #expect(vim.cursor == 22)
        vim.handle("0")
        #expect(vim.cursor == 19)
    }
    @Test func editsAreInertAndVisualYankWorks() {
        var vim = ReadOnlyVimNavigation(text: "alpha beta\ngamma\n")
        for key in ["i", "a", "d", "d", "x", "p", "r", "u", "ctrl+r"] { vim.handle(key) }
        #expect(vim.cursor == 0)
        for key in ["v", "e", "y"] { vim.handle(key) }
        #expect(vim.yankedText == "alpha")
        #expect(vim.selection.length == 0)
        for key in ["g", "g", "V", "j", "y"] { vim.handle(key) }
        #expect(vim.yankedText == "alpha beta\ngamma\n")
    }
    @Test func unicodeAndShortLines() {
        var vim = ReadOnlyVimNavigation(text: "a👩🏽‍💻bc\nx\n123456\n")
        vim.handle("l")
        #expect(vim.cursor == 1)
        vim.handle("l")
        #expect(vim.cursor == ("a👩🏽‍💻" as NSString).length)
        vim.handle("j")
        vim.handle("j")
        let expected = ("a👩🏽‍💻bc\nx\n12" as NSString).length
        #expect(vim.cursor == expected)
    }
    @Test func searchMarksAndJumps() {
        var vim = ReadOnlyVimNavigation(text: "alpha beta\ngamma beta\n")
        for key in ["m", "a", "/", "b", "e", "t", "a", "enter"] { vim.handle(key) }
        #expect(vim.cursor == 6)
        vim.handle("n")
        #expect(vim.cursor == 17)
        vim.handle("N")
        #expect(vim.cursor == 6)
        for key in ["`", "a"] { vim.handle(key) }
        #expect(vim.cursor == 0)
        vim.handle("ctrl+o")
        #expect(vim.cursor == 6)
        vim.handle("ctrl+i")
        #expect(vim.cursor == 0)
    }
    @Test func viewportAndCancellation() {
        var vim = ReadOnlyVimNavigation(text: "first\nlast")
        vim.handle("ctrl+d")
        #expect(vim.viewportAction == .page(0.5))
        for key in ["z", "z"] { vim.handle(key) }
        #expect(vim.viewportAction == .align(0.5))
        vim.handle("g")
        vim.cancelPendingInput()
        vim.handle("G")
        #expect(vim.cursor == 6)
        for key in ["g", "g"] { vim.handle(key) }
        #expect(vim.cursor == 0)
    }
    @Test func trailingNewlineDoesNotCreatePhantomLastLine() {
        var vim = ReadOnlyVimNavigation(text: "first\nlast\n")
        vim.handle("G")
        #expect(vim.cursor == 6)
        vim.handle("$")
        #expect(vim.cursor == 9)
        vim.handle("w")
        #expect(vim.cursor == 9)
    }
    @Test func emptyAndHugeCounts() {
        var vim = ReadOnlyVimNavigation(text: "")
        for key in ["9", "9", "9", "9", "9", "j", "G", "w", "e", "V", "y"] { vim.handle(key) }
        #expect(vim.cursor == 0)
        #expect(vim.yankedText == "")
    }
}
