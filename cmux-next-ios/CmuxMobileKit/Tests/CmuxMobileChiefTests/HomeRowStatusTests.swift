import CmuxMobileDesign
import Foundation
import Testing
@testable import CmuxMobileChief

/// Settings → Home Row Status: a Home row's agent state in Workspaces' words, its leading mark
/// and the pinned tile's short ask. Off by default, so nobody sees a change unless they pick it.
struct HomeRowStatusTests {
    private func status(_ state: MacHomeRow.ChiefState?, ask: HomeRowStatus.Ask? = nil, unread: Bool = false,
                        preview: String = "Refactor transport layer") -> HomeRowStatus? {
        HomeRowStatus.of(chiefState: state, ask: ask, agent: "Claude", isUnread: unread, preview: preview)
    }

    @Test func aWaitingAgentSaysWhatItWaitsFor() {
        #expect(status(.waiting, ask: .permission)?.line == "Claude is asking permission \u{00B7} Refactor transport layer")
        #expect(status(.waiting, ask: .question)?.line == "Claude has a question \u{00B7} Refactor transport layer")
        #expect(status(.waiting)?.line == "Claude is waiting \u{00B7} Refactor transport layer")
        // Read or unread, a waiting agent waits.
        #expect(status(.waiting, unread: true)?.phrase == "Claude is waiting")
    }

    @Test func workingAndDoneReadAsWorkspacesDoes() {
        #expect(status(.working)?.line == "Claude is working \u{00B7} Refactor transport layer")
        #expect(status(.idle, unread: true)?.line == "Done \u{00B7} Refactor transport layer")
        #expect(status(.working, preview: "")?.line == "Claude is working")
    }

    @Test func anIdleReadRowOrARowWithNoAgentSaysNothingNew() {
        #expect(status(.idle) == nil)
        #expect(status(nil) == nil)
        #expect(status(nil, unread: true) == nil)
    }

    @Test func theMarkFollowsTheStateNotUnread() {
        #expect(HomeRowStatus.mark(status(.waiting, unread: true), isUnread: true) == .needsYou)
        #expect(HomeRowStatus.mark(status(.waiting), isUnread: false) == .needsYou)
        #expect(HomeRowStatus.mark(status(.working, unread: true), isUnread: true) == .working)
        #expect(HomeRowStatus.mark(status(.idle, unread: true), isUnread: true) == .unread)
        #expect(HomeRowStatus.mark(status(.idle), isUnread: false) == HomeRowStatus.Mark.none)
        // A conversation with no agent keeps the plain unread dot.
        #expect(HomeRowStatus.mark(status(nil, unread: true), isUnread: true) == .unread)
    }

    @Test func aWaitingTileShowsTheAskShortNotTheCutPreview() {
        let waiting = status(.waiting, ask: .permission)
        #expect(HomeRowStatus.tileBubble(waiting, shortAsk: "Allow cargo test?") == "Allow cargo test?")
        #expect(HomeRowStatus.tileBubble(waiting, shortAsk: nil) == "Claude is asking permission")
        #expect(HomeRowStatus.tileBubble(waiting, shortAsk: "  ") == "Claude is asking permission")
        // Not waiting: the tile keeps its preview bubble.
        #expect(HomeRowStatus.tileBubble(status(.working), shortAsk: "Allow cargo test?") == nil)
        #expect(HomeRowStatus.tileBubble(nil, shortAsk: "Allow cargo test?") == nil)
    }

    @Test func aLongAskIsCutAtAWord() {
        #expect(HomeRowStatus.short("Allow cargo test -p cnx-link?") == "Allow cargo test -p cnx-link?")
        #expect(HomeRowStatus.short("Allow Claude to run cargo test -p cnx-link in cmux?") == "Allow Claude to run cargo test\u{2026}")
        #expect(HomeRowStatus.short("First line?\nSecond line") == "First line?")
    }

    @Test func theLookIsOffUnlessPicked() throws {
        let defaults = try #require(UserDefaults(suiteName: "HomeRowStatusTests.\(UUID().uuidString)"))
        #expect(CmuxMobileHomeRowLook.current(defaults) == .now)
        #expect(!CmuxMobileHomeRowLook.now.says && !CmuxMobileHomeRowLook.now.movesMark && !CmuxMobileHomeRowLook.now.showsAsk)
        defaults.set("bogus", forKey: CmuxMobilePreferences.Key.homeRowLook)
        #expect(CmuxMobileHomeRowLook.current(defaults) == .now)
        defaults.set("wordsAndMark", forKey: CmuxMobilePreferences.Key.homeRowLook)
        #expect(CmuxMobileHomeRowLook.current(defaults) == .wordsAndMark)
        #expect(CmuxMobileHomeRowLook.words.says && !CmuxMobileHomeRowLook.words.movesMark)
        #expect(CmuxMobileHomeRowLook.wordsMarkAndAsk.movesMark && CmuxMobileHomeRowLook.wordsMarkAndAsk.showsAsk)
    }
}
