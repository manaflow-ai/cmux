import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// R110: while the address bar's suggestion list is open, Ctrl-N / Ctrl-J
/// move the selection down and Ctrl-P / Ctrl-K up, through the one list
/// path (`listFocus`, list.next / list.previous, which hand the field a Down
/// or Up arrow). With the list closed the field keeps its own Control keys
/// (Ctrl-K deletes to the end of the line).
@MainActor
struct OmnibarListKeyTests {
    typealias M = KeyOwnershipMatrixTests

    @Test func controlKeysMoveTheOpenSuggestionList() throws {
        let router = M.services().keyRouter!
        let addressBar = M.focused(.browser, tab: "b1", target: .addressBar)
        for (event, action) in try ListNavigationKeyTests.keys() {
            guard case .run(let candidate) = router.decide(event, focus: addressBar, keyWindow: .content,
                                                           facts: KeyRouter.Facts(omnibarListOpen: true)) else {
                Issue.record("\(event.charactersIgnoringModifiers ?? ""): not run while the list is open"); continue
            }
            #expect(candidate.id == action)
        }
        let open = KeyRouter.keyContext(for: addressBar, appContext: [], facts: KeyRouter.Facts(omnibarListOpen: true))
        #expect(open[KeyContext.listFocus] == .bool(true))
    }

    @Test func aClosedListLeavesTheControlKeysToTheField() throws {
        let router = M.services().keyRouter!
        let addressBar = M.focused(.browser, tab: "b1", target: .addressBar)
        for (event, action) in try ListNavigationKeyTests.keys() {
            if case .run(let candidate) = router.decide(event, focus: addressBar, keyWindow: .content, facts: KeyRouter.Facts()) {
                #expect(candidate.id != action, "\(event.charactersIgnoringModifiers ?? "")")
            }
        }
        // The flag means nothing outside the address bar.
        let elsewhere = KeyRouter.keyContext(for: M.terminal, appContext: [], facts: KeyRouter.Facts(omnibarListOpen: true))
        #expect(elsewhere[KeyContext.listFocus] == nil)
    }
}
