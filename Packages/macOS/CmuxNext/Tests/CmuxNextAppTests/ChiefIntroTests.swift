import AppKit
import CmuxHomeCore
import CmuxNextTestSupport
import Foundation
@testable import CmuxNextHome
@testable import CmuxNextHomeModel
import Testing

/// The Chief's first-open intro: the welcome once per install for the only Chief, and a new
/// Chief beside others asks what it should focus on, once per Chief.
@Suite(.serialized) struct ChiefIntroTests {
    /// A defaults suite of its own, so the test never reads or writes the person's settings.
    static func isolatedDefaults() -> (defaults: UserDefaults, suite: String) {
        let suite = "cmux-chief-intro-\(UUID().uuidString)"
        return (UserDefaults(testSuiteName: suite) ?? .standard, suite)
    }

    static let first = CmuxHomeCore.ConversationID("chief-first")
    static let second = CmuxHomeCore.ConversationID("chief-second")

    /// The only Chief gets the welcome; the Chief made next to it asks what to focus on.
    @Test func theOnlyChiefWelcomesAndANewChiefBesideOthersAsksForAFocus() {
        let (defaults, suite) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChiefIntroStore(defaults: defaults)
        #expect(store.intro(for: Self.first, otherChiefs: 0) == .welcome)
        store.markShown(.welcome, for: Self.first)
        #expect(store.intro(for: Self.first, otherChiefs: 0) == nil)
        #expect(store.intro(for: Self.second, otherChiefs: 1) == .askFocus)
        store.markShown(.askFocus, for: Self.second)
        #expect(store.intro(for: Self.second, otherChiefs: 1) == nil, "each Chief introduces itself once")
        #expect(store.intro(for: CmuxHomeCore.ConversationID("chief-third"), otherChiefs: 2) == .askFocus)
    }

    /// The welcome shows once per install, even on another empty Chief that is alone again.
    @Test func theWelcomeShowsOncePerInstall() {
        let (defaults, suite) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        ChiefIntroStore(defaults: defaults).markShown(.welcome, for: Self.first)
        // A new store over the same defaults is the next launch of cmux.
        #expect(ChiefIntroStore(defaults: defaults).intro(for: Self.second, otherChiefs: 0) == nil)
    }

    /// An install that saw the old once-per-install intro still gets a new Chief's question.
    @Test func anOlderInstallThatSawTheWelcomeStillGetsTheQuestion() {
        let (defaults, suite) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "home.firstRun.chiefIntroShown")
        let store = ChiefIntroStore(defaults: defaults)
        #expect(store.intro(for: Self.first, otherChiefs: 0) == nil)
        #expect(store.intro(for: Self.second, otherChiefs: 3) == .askFocus)
    }

    /// The two intros say different things, and the question asks for a focus.
    @Test func theQuestionIsNotTheWelcome() {
        #expect(HomeStrings.chiefIntro(.welcome) == HomeStrings.firstRunIntro)
        #expect(HomeStrings.chiefIntro(.askFocus) != HomeStrings.firstRunIntro)
        #expect(HomeStrings.chiefIntro(.askFocus).contains("?"))
    }
}
