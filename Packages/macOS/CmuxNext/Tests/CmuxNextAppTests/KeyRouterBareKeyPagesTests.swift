import CmuxNextActions
import Testing
@testable import CmuxNextApp

/// The key router asks a focused page for bare keys only when its context bits can include
/// ``ActionContext/bareKeyOwners`` (derived from those bits, not a second list): the diff viewer and a
/// markdown page can; the code editor and any other page never pay for the window facts.
@Suite struct KeyRouterBareKeyPagesTests {
    @Test func onlyBareKeyOwningPagesAreAsked() {
        #expect(KeyRouter.pageMayOwnBareKeys(KeyRouter.diffPageID))
        #expect(KeyRouter.pageMayOwnBareKeys(KeyRouter.markdownPageID))
        #expect(!KeyRouter.pageMayOwnBareKeys(KeyRouter.codeEditorPageID))
        #expect(!KeyRouter.pageMayOwnBareKeys("cmux.home-channels"))
    }

    @Test func thePageBitsAreTheKeyContextsBits() {
        #expect(KeyRouter.pageContext(pageID: KeyRouter.markdownPageID, markdownReadOnly: false) == .markdown(readOnly: false))
        #expect(KeyRouter.pageContext(pageID: KeyRouter.diffPageID, markdownReadOnly: false).contains(.diffViewerFocused))
        #expect(KeyRouter.pageContext(pageID: nil, markdownReadOnly: true).isEmpty)
    }
}
