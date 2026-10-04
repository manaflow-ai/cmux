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
