import AppKit
import Foundation
@testable import CmuxNextHome
import Testing

/// The Chief's first-open intro shows once per install, never again after it was shown.
@Suite(.serialized) struct ChiefIntroTests {
    /// A defaults suite of its own, so the test never reads or writes the person's settings.
    static func isolatedDefaults() -> (defaults: UserDefaults, suite: String) {
        let suite = "cmux-chief-intro-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite) ?? .standard, suite)
    }

    @Test func aFreshInstallShowsTheIntroThenNever() {
        let (defaults, suite) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChiefIntroStore(defaults: defaults)
        #expect(store.shouldShow)
        store.markShown()
        #expect(!store.shouldShow)
    }

    @Test func theShownFlagSurvivesARelaunch() {
        let (defaults, suite) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        ChiefIntroStore(defaults: defaults).markShown()
        // A new store over the same defaults is the next launch of cmux.
        #expect(!ChiefIntroStore(defaults: defaults).shouldShow)
    }
}

/// The intro's place in the first-run panel: above the hero when the column has room, gone when it is tight.
@MainActor @Suite(.serialized) struct ChiefIntroPanelTests {
    @Test func theIntroShowsWhileItFitsAndLeavesWhenTheColumnIsTight() {
        let panel = HomeFirstRunView(frame: NSRect(x: 0, y: 0, width: 340, height: 700))
        panel.setIntro(HomeStrings.firstRunIntro)
        panel.layoutSubtreeIfNeeded()
        #expect(panel.introText == HomeStrings.firstRunIntro)
        #expect(!panel.intro.isHidden)

        panel.setFrameSize(NSSize(width: 340, height: 60))
        panel.layoutSubtreeIfNeeded()
        #expect(panel.intro.isHidden)

        panel.setFrameSize(NSSize(width: 340, height: 700))
        panel.layoutSubtreeIfNeeded()
        #expect(!panel.intro.isHidden)

        panel.setIntro(nil)
        panel.layoutSubtreeIfNeeded()
        #expect(panel.intro.isHidden)
    }
}
