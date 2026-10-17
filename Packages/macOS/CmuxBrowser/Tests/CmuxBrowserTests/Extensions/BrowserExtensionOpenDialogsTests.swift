import Foundation
import Testing
@testable import CmuxBrowser

@MainActor
@Suite("Browser extension open dialogs")
struct BrowserExtensionOpenDialogsTests {
    private func content(_ name: String) -> BrowserExtensionPromptContent {
        BrowserExtensionPromptContent(automation: .loadUnpacked, name: name)
    }

    @Test("lists open dialogs oldest first with their titles")
    func listsOpenDialogs() {
        let dialogs = BrowserExtensionOpenDialogs()
        let first = dialogs.open(content("/tmp/a")) { _ in }
        let second = dialogs.open(content("/tmp/b")) { _ in }
        #expect(dialogs.waiting.map(\.id) == [first, second])
        #expect(dialogs.waiting.first?.title == content("/tmp/a").title)
        #expect(dialogs.waiting.first?.acceptTitle == content("/tmp/a").acceptTitle)
    }

    @Test("answering runs the dialog's answer once and removes it")
    func answersOnce() {
        let dialogs = BrowserExtensionOpenDialogs()
        var answers: [Bool] = []
        let id = dialogs.open(content("/tmp/a")) { answers.append($0) }
        #expect(dialogs.answer(id, accepted: true))
        #expect(!dialogs.answer(id, accepted: false))
        #expect(answers == [true])
        #expect(dialogs.waiting.isEmpty)
    }

    @Test("a dialog closed another way leaves the list")
    func closedDialogLeaves() {
        let dialogs = BrowserExtensionOpenDialogs()
        var answers: [Bool] = []
        let id = dialogs.open(content("/tmp/a")) { answers.append($0) }
        dialogs.close(id)
        #expect(dialogs.waiting.isEmpty)
        #expect(!dialogs.answer(id, accepted: true))
        #expect(answers.isEmpty)
    }

    @Test("an unknown id answers nothing")
    func unknownID() {
        #expect(!BrowserExtensionOpenDialogs().answer(42, accepted: true))
    }
}
