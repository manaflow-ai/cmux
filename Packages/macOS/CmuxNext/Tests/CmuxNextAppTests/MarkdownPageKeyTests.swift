import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextPages
import Testing

/// The markdown page (diff-host S6) in the key dispatcher (R59): a page tab
/// that shows `cmux.markdown` sets the `pageId` context key and the
/// `markdownFocused` bit, so Cmd-S there runs Markdown: Save, which sends
/// the page command `save`; Cmd-S elsewhere keeps its other owners.
@MainActor
struct MarkdownPageKeyTests {
    typealias M = KeyOwnershipMatrixTests
    typealias K = KeyInterceptionTests

    static let markdownPage = M.focused(.page, tab: "local-page:markdown:1")

    @Test func aMarkdownPageSetsItsContextKeys() {
        let context = KeyRouter.keyContext(for: Self.markdownPage, appContext: [],
                                           facts: KeyRouter.Facts(pageID: PageDescriptor.markdown.id))
        #expect(context["pageId"] == .string("cmux.markdown"))
        #expect(context.bits.contains(.markdownFocused))
        let other = KeyRouter.keyContext(for: Self.markdownPage, appContext: [], facts: KeyRouter.Facts(pageID: "cmux.history"))
        #expect(!other.bits.contains(.markdownFocused))
    }

    @Test func commandSInAMarkdownPageSavesThroughThePageCommand() throws {
        let router = M.services().keyRouter!
        let save = try K.key("s", keyCode: 1, [.command])
        let decision = router.decide(save, focus: Self.markdownPage, keyWindow: .content,
                                     facts: KeyRouter.Facts(pageID: PageDescriptor.markdown.id))
        #expect(decision == .run(KeyRouter.Candidate(id: "markdownSave", tier: .content, source: .registry(argument: nil))))
        let elsewhere = router.decide(save, focus: Self.markdownPage, keyWindow: .content, facts: KeyRouter.Facts(pageID: "cmux.history"))
        #expect(elsewhere != decision)
        #expect(MarkdownPageCommand.forAction["markdownSave"] == "save")
        #expect(PageDescriptor.markdown.commands.contains("save"))
    }
}

extension MarkdownPageKeyTests {
    @Test func theMarkdownIdMatchesTheDescriptor() {
        #expect(KeyRouter.markdownPageID == PageDescriptor.markdown.id)
    }
}

extension MarkdownPageKeyTests {
    /// hq-48 S6: Cmd-Shift-K inserts a link (decision K1 moved it off Cmd-K), Cmd-[ / Cmd-] go back and forward in
    /// a focused markdown page, through its page commands; elsewhere those
    /// keys keep their owners.
    @Test func linkBackAndForwardInAMarkdownPage() throws {
        let router = M.services().keyRouter!
        let markdown = KeyRouter.Facts(pageID: PageDescriptor.markdown.id)
        let cases: [(NSEvent, ActionID, String)] = [
            (try K.key("k", keyCode: 40, [.command, .shift]), "markdownLink", "link"),
            (try K.key("[", keyCode: 33, [.command]), "markdownBack", "back"),
            (try K.key("]", keyCode: 30, [.command]), "markdownForward", "forward"),
        ]
        for (event, action, command) in cases {
            let decision = router.decide(event, focus: Self.markdownPage, keyWindow: .content, facts: markdown)
            guard case .run(let candidate) = decision else { Issue.record("\(action): \(decision)"); continue }
            #expect(candidate.id == action)
            #expect(MarkdownPageCommand.forAction[action.rawValue] == command)
            #expect(PageDescriptor.markdown.commands.contains(command))
            let other = router.decide(event, focus: Self.markdownPage, keyWindow: .content, facts: KeyRouter.Facts(pageID: "cmux.history"))
            if case .run(let elsewhere) = other { #expect(elsewhere.id != action) }
        }
    }
}
