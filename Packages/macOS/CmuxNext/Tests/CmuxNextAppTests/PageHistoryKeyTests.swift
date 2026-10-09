import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// Page history (history.md 4.2b): on a page with its own history (the App
/// Store), Cmd-[ / Cmd-] run Go Back / Go Forward, the same actions as the
/// titlebar arrows; on any other non-browser page they stay consumed.
@MainActor
struct PageHistoryKeyTests {
    typealias M = KeyOwnershipMatrixTests
    typealias K = KeyInterceptionTests

    static let storePage = M.focused(.page, tab: "local-page:app-store:1")

    @Test func commandBracketsRunGoBackAndForwardOnAPageWithHistory() throws {
        let router = M.services().keyRouter
        let cases: [(String, UInt16, ActionID)] = [("[", 33, "focusHistoryBack"), ("]", 30, "focusHistoryForward")]
        for (key, code, action) in cases {
            let event = try K.key(key, keyCode: code, [.command])
            let decision = router.decide(event, focus: Self.storePage, keyWindow: .content, facts: KeyRouter.Facts(showsPageHistory: true))
            guard case .run(let candidate) = decision else {
                Issue.record("\(action): \(decision)")
                continue
            }
            #expect(candidate.id == action)
            #expect(router.decide(event, focus: Self.storePage, keyWindow: .content, facts: KeyRouter.Facts()) == .consume)
        }
    }

    @Test func otherChordsKeepTheirOwnersOnAPageWithHistory() throws {
        let router = M.services().keyRouter
        let event = try K.key("s", keyCode: 1, [.command, .shift])
        let plain = router.decide(event, focus: Self.storePage, keyWindow: .content, facts: KeyRouter.Facts())
        #expect(router.decide(event, focus: Self.storePage, keyWindow: .content, facts: KeyRouter.Facts(showsPageHistory: true)) == plain)
    }
}
