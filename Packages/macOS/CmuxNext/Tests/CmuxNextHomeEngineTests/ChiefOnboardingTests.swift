import AppKit
@testable import CmuxNextHome
import CmuxNextHomeModel
import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// Meet Chief: a fresh install's first-run introduction on the empty Chief chat (David Beyer's first run,
/// 2026-11-20: who Chief is, what it may do and what it does for him were unclear). It starts once, on a fresh
/// install only, holds Chief's welcome until it ends, writes the person's permission, density and text size picks
/// through the settings, and its card draws each step and reports each click.
@MainActor
@Suite(.serialized) struct ChiefOnboardingTests {
    /// The settings Meet Chief changes, in memory; `failing` refuses the next write.
    @MainActor final class FakeSettings: ChiefOnboardingSettings {
        var mode: ChiefPermissionMode = .bypass
        var modeManaged = false
        var density: ChiefOnboardingDensity? = .cozy
        var textSize: Double = 12
        let textSizeRange: ClosedRange<Double> = 10...16
        var failing = false
        private(set) var writes: [String] = []

        struct Refused: Error {}

        func setMode(_ mode: ChiefPermissionMode) async throws {
            writes.append("mode=\(mode.rawValue)")
            if failing { throw Refused() }
            self.mode = mode
        }

        func setDensity(_ density: ChiefOnboardingDensity) async throws {
            writes.append("density=\(density.rawValue)")
            if failing { throw Refused() }
            self.density = density
        }

        func setTextSize(_ points: Double) async throws {
            writes.append("textSize=\(Int(points))")
            if failing { throw Refused() }
            textSize = points
        }
    }

    /// A defaults suite of its own, so the test never reads or writes the person's settings.
    static func isolatedDefaults() -> (defaults: UserDefaults, suite: String) {
        let suite = "cmux-chief-onboarding-\(UUID().uuidString)"
        return (UserDefaults(testSuiteName: suite) ?? .standard, suite)
    }

    /// A fresh install starts it at the first step; finishing ends it for good, also on the next launch.
    @Test func aFreshInstallMeetsChiefOnceAndItEndsForGood() {
        let (defaults, suite) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let onboarding = ChiefOnboarding(defaults: defaults, settings: FakeSettings())
        #expect(!onboarding.shows)
        #expect(onboarding.begin(freshInstall: true))
        #expect(onboarding.shows && onboarding.step == .meet)
        onboarding.finish()
        #expect(!onboarding.shows)
        // The next launch: a new model over the same defaults, even one that calls itself a first run.
        let next = ChiefOnboarding(defaults: defaults, settings: FakeSettings())
        #expect(!next.begin(freshInstall: true))
        #expect(!next.shows)
    }

    /// The first run shows on the only, empty Chief chat and its first message ends it. Meet Chief from the palette
    /// (``ChiefOnboarding/reopen()``) shows on any Chief chat, also one with messages and beside other Chiefs, and
    /// ends at the next message sent there.
    @Test func thePaletteShowsItAgainInAChatWithMessages() {
        let (defaults, suite) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let onboarding = ChiefOnboarding(defaults: defaults, settings: FakeSettings())
        #expect(onboarding.begin(freshInstall: true))
        #expect(onboarding.place(chatAt: 0, shownAt: nil, otherChiefs: 0) == .shows)
        #expect(onboarding.place(chatAt: 0, shownAt: nil, otherChiefs: 1) == .hidden)
        #expect(onboarding.place(chatAt: 1, shownAt: 0, otherChiefs: 0) == .ends)
        onboarding.finish()
        #expect(onboarding.place(chatAt: 7, shownAt: nil, otherChiefs: 2) == .hidden)

        onboarding.reopen()
        #expect(onboarding.shows && onboarding.step == .meet)
        #expect(onboarding.place(chatAt: 7, shownAt: nil, otherChiefs: 2) == .shows)
        #expect(onboarding.place(chatAt: 7, shownAt: 7, otherChiefs: 2) == .shows)
        #expect(onboarding.place(chatAt: 8, shownAt: 7, otherChiefs: 2) == .ends)
        onboarding.finish()
        #expect(onboarding.place(chatAt: 0, shownAt: nil, otherChiefs: 0) == .hidden)
    }

    /// A relaunch before it was finished shows it again from the first step.
    @Test func aPendingOnboardingReturnsOnTheNextLaunch() {
        let (defaults, suite) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ChiefOnboarding(defaults: defaults, settings: FakeSettings())
        first.begin(freshInstall: true)
        first.next()
        let relaunch = ChiefOnboarding(defaults: defaults, settings: FakeSettings())
        #expect(relaunch.shows && relaunch.step == .meet && relaunch.decided)
    }

    /// An upgrade never starts it; a launch that skips onboarding (showcase, captures) neither, and a pending
    /// one waits for the next launch that does not skip.
    @Test func anUpgradeOrASkippedLaunchNeverStartsIt() {
        let (defaults, suite) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let upgrade = ChiefOnboarding(defaults: defaults, settings: FakeSettings())
        #expect(!upgrade.begin(freshInstall: false))
        #expect(!upgrade.shows)
        let (fresh, freshSuite) = Self.isolatedDefaults()
        defer { fresh.removePersistentDomain(forName: freshSuite) }
        let skipped = ChiefOnboarding(defaults: fresh, settings: FakeSettings(), skipsOnboarding: true)
        #expect(!skipped.begin(freshInstall: true))
        #expect(!skipped.shows && !skipped.holdsWelcome)
        ChiefOnboarding(defaults: fresh, settings: FakeSettings()).begin(freshInstall: true)
        #expect(!ChiefOnboarding(defaults: fresh, settings: FakeSettings(), skipsOnboarding: true).shows)
        #expect(ChiefOnboarding(defaults: fresh, settings: FakeSettings()).shows)
    }

    /// Chief's welcome (and the Set Up cmux card) wait until the launch decided, and while it shows.
    @Test func theWelcomeWaitsUntilTheLaunchDecidedAndWhileItShows() {
        let (defaults, suite) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let onboarding = ChiefOnboarding(defaults: defaults, settings: FakeSettings())
        #expect(onboarding.holdsWelcome, "a fresh launch has not decided yet: the welcome must not play first")
        onboarding.begin(freshInstall: true)
        #expect(onboarding.holdsWelcome)
        onboarding.finish()
        #expect(!onboarding.holdsWelcome)
        let (other, otherSuite) = Self.isolatedDefaults()
        defer { other.removePersistentDomain(forName: otherSuite) }
        let upgrade = ChiefOnboarding(defaults: other, settings: FakeSettings())
        upgrade.begin(freshInstall: false)
        #expect(!upgrade.holdsWelcome, "an upgrade's welcome is never held")
    }

    /// Simple first: who Chief is, then what it may do, then how cmux looks; Back goes one step back, and the last
    /// step's button ends it.
    @Test func theStepsGoFromSimpleToMoreAndTheLastOneStartsTheChat() {
        let (defaults, suite) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let onboarding = ChiefOnboarding(defaults: defaults, settings: FakeSettings())
        onboarding.begin(freshInstall: true)
        #expect(onboarding.steps == [.meet, .access, .look])
        #expect(!onboarding.canGoBack)
        onboarding.back()
        #expect(onboarding.step == .meet)
        onboarding.next()
        #expect(onboarding.step == .access && onboarding.canGoBack)
        onboarding.next()
        #expect(onboarding.step == .look && onboarding.isLast)
        onboarding.back()
        #expect(onboarding.step == .access)
        onboarding.next()
        onboarding.next()
        #expect(!onboarding.shows)
        #expect(defaults.string(forKey: ChiefOnboarding.stateKey) == "done")
    }

    /// A permission pick shows at once and is written as the person's setting.
    @Test func aPermissionPickShowsAtOnceAndIsWritten() async {
        let (defaults, suite) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = FakeSettings()
        let onboarding = ChiefOnboarding(defaults: defaults, settings: settings)
        onboarding.begin(freshInstall: true)
        #expect(onboarding.mode == .bypass, "the card shows the mode in effect, Bypass by default")
        let write = onboarding.choose(.auto)
        #expect(onboarding.mode == .auto, "the pick shows before its write ends")
        await write?.value
        #expect(settings.writes == ["mode=auto"])
        #expect(onboarding.mode == .auto && settings.mode == .auto && !onboarding.writeFailed)
        #expect(onboarding.choose(.auto) == nil, "the mode in effect is not written again")
    }

    /// A pick that does not save puts the setting's mode back and says so.
    @Test func aPickThatDoesNotSaveShowsTheSettingAgain() async {
        let (defaults, suite) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = FakeSettings()
        settings.failing = true
        let onboarding = ChiefOnboarding(defaults: defaults, settings: settings)
        onboarding.begin(freshInstall: true)
        await onboarding.choose(.manual)?.value
        #expect(onboarding.mode == .bypass)
        #expect(onboarding.writeFailed)
        settings.failing = false
        await onboarding.choose(.manual)?.value
        #expect(onboarding.mode == .manual && !onboarding.writeFailed)
    }

    /// An administrator's mode is shown, never offered.
    @Test func aManagedModeIsNotOffered() {
        let (defaults, suite) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = FakeSettings()
        settings.mode = .manual
        settings.modeManaged = true
        let onboarding = ChiefOnboarding(defaults: defaults, settings: settings)
        #expect(!onboarding.canChooseMode)
        #expect(onboarding.choose(.bypass) == nil)
        #expect(settings.writes.isEmpty && onboarding.mode == .manual)
    }

    /// The density and the text size are written as picked; the text stays in the setting's range.
    @Test func densityAndTextSizeAreWrittenAndTheTextStaysInRange() async {
        let (defaults, suite) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = FakeSettings()
        let onboarding = ChiefOnboarding(defaults: defaults, settings: settings)
        await onboarding.chooseDensity(.comfortable)?.value
        #expect(onboarding.density == .comfortable)
        await onboarding.changeTextSize(by: 1)?.value
        #expect(onboarding.textSize == 13)
        settings.textSize = 16
        #expect(!onboarding.canGrowText)
        #expect(onboarding.changeTextSize(by: 1) == nil)
        settings.textSize = 10
        #expect(!onboarding.canShrinkText && onboarding.canGrowText)
        #expect(settings.writes == ["density=comfortable", "textSize=13"])
        settings.density = nil
        #expect(onboarding.density == nil, "a density Meet Chief does not offer shows none of its three picked")
    }

    /// Its modes and densities are the values the settings take, so every pick is a write Settings accepts.
    @Test func itsValuesAreTheSettingsOwn() throws {
        let mode = try #require(SettingsSchema.descriptor(for: ["chief", "permissionMode"]))
        for value in ChiefPermissionMode.allCases { #expect(mode.accepts(.string(value.rawValue)), "\(value)") }
        #expect(mode.defaultValue == .string(ChiefPermissionMode.default.rawValue))
        let density = try #require(SettingsSchema.descriptor(for: ["appearance", "density"]))
        for value in ChiefOnboardingDensity.allCases { #expect(density.accepts(.string(value.rawValue)), "\(value)") }
    }

    /// The card draws each step (its title, its choices, its button) and reports each click.
    @Test func theCardDrawsEachStepAndReportsItsClicks() throws {
        let (defaults, suite) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let onboarding = ChiefOnboarding(defaults: defaults, settings: FakeSettings())
        onboarding.begin(freshInstall: true)
        let card = HomeChiefOnboardingCard()
        var clicks: [HomeChiefOnboardingAction] = []
        card.onAction = { clicks.append($0) }

        card.apply(try #require(HomeChiefOnboardingState(onboarding)))
        #expect(card.title.stringValue == HomeChiefOnboardingStrings.title(.meet))
        #expect(card.features.count == 3, "agents, memory, follow-ups")
        #expect(card.back.isHidden)
        #expect(card.primary.title == HomeChiefOnboardingStrings.next)
        #expect(card.height(for: 400) > 0)

        onboarding.next()
        card.apply(try #require(HomeChiefOnboardingState(onboarding)))
        #expect(card.title.stringValue == HomeChiefOnboardingStrings.title(.access))
        #expect(card.choices.map(\.mode) == ChiefPermissionMode.allCases)
        #expect(card.choices.filter(\.isOn).map(\.mode) == [.bypass])
        #expect(card.choices.first?.title.stringValue == HomeChiefOnboardingCard.modeName(.bypass))
        #expect(HomeChiefOnboardingCard.modeName(.bypass) != ChiefPermissionMode.bypass.rawValue, "named as Settings names it")
        #expect(!card.note.isHidden && !card.openSettings.isHidden && !card.back.isHidden)
        _ = card.choices[1].accessibilityPerformPress()
        _ = card.openSettings.accessibilityPerformPress()

        onboarding.next()
        card.apply(try #require(HomeChiefOnboardingState(onboarding)))
        #expect(card.title.stringValue == HomeChiefOnboardingStrings.title(.look))
        #expect(card.choices.isEmpty && card.features.isEmpty)
        #expect(!card.densityTrack.isHidden && card.densities.filter(\.isOn).count == 1)
        #expect(card.textSize.stringValue == HomeChiefOnboardingStrings.points(12))
        #expect(card.primary.title == HomeChiefOnboardingStrings.start)
        _ = card.densities[2].accessibilityPerformPress()
        _ = card.larger.accessibilityPerformPress()
        _ = card.primary.accessibilityPerformPress()
        _ = card.skip.accessibilityPerformPress()

        #expect(clicks == [.choose(.auto), .openSettings(.access), .density(.comfortable), .textSize(1), .next, .skip])
    }

    /// A managed mode shows alone, not as a choice, with who sets it.
    @Test func theCardShowsAManagedModeAlone() {
        let state = HomeChiefOnboardingState(step: .access, index: 1, count: 3, mode: .manual, canChooseMode: false, modeManaged: true,
                                             density: .cozy, textSize: 12, canShrinkText: true, canGrowText: true, writeFailed: false)
        let card = HomeChiefOnboardingCard()
        card.apply(state)
        #expect(card.choices.filter { !$0.isHidden }.map(\.mode) == [.manual])
        #expect(card.choices.allSatisfy { !$0.isEnabled })
        #expect(card.status.stringValue == HomeChiefOnboardingStrings.managed)
        #expect(card.openSettings.isHidden)
    }
}
