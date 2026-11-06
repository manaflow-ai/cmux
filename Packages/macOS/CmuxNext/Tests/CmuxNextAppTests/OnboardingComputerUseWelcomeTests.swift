// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CmuxNextDesign
@testable import CmuxNextOnboarding
import Foundation
import Testing

/// The first-run Computer Use page (Agents Can Use Your Apps): it opens once, after the Agents
/// step closes; Allow Access keeps Computer Use on and opens the setup that walks the macOS
/// grants; Not Now ends it without asking for anything; a managed policy or an upgrade never
/// shows it; its blue cursor tours only while loops are allowed.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct OnboardingComputerUseWelcomeTests {
    private func defaults() throws -> UserDefaults {
        let suite = "cmux-computer-use-first-run-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func presenter(_ source: MockComputerUsePermissionSource? = nil)
        -> (OnboardingWindowPresenter, () -> [OnboardingModel.Step]) {
        var shown: [OnboardingModel.Step] = []
        let presenter = OnboardingWindowPresenter(makeModel: { step in
            let services = MockOnboardingServices()
            services.computerUseSource = source
            return OnboardingModel(services: services, step: step)
        }, activeLook: nil, present: { shown.append($0.model.step) })
        return (presenter, { shown })
    }

    @Test func thePageSaysComputerUseIsBuiltInAndOn() {
        let model = OnboardingModel(services: MockOnboardingServices(), step: .computerUseWelcome)
        #expect(model.steps == [.computerUseWelcome])
        #expect(model.primaryTitle == OnboardingStrings.computerUseWelcomeAllow)
        #expect(model.skipTitle == OnboardingStrings.computerUseNotNow)
        #expect(model.canAdvance)
        #expect(OnboardingStrings.computerUseWelcomeBody.contains("Claude"))
        #expect(OnboardingStrings.computerUseWelcomeDetail.contains("Settings > Computer Use"))
        #expect(ObjectIdentifier(OnboardingModel.Step.computerUseWelcome.screen) == ObjectIdentifier(StandardComputerUseWelcome.self))
    }

    /// Allow Access turns Computer Use on (it may have been off) and hands over to the setup
    /// window for the grants once this page closed; it never waits on macOS.
    @Test func allowAccessOpensTheGrantSetup() throws {
        let source = MockComputerUsePermissionSource(current: .off)
        let (presenter, shown) = presenter(source)
        presenter.showComputerUseAtFirstRun(isFirstRun: true, available: true, defaults: try defaults())
        #expect(shown() == [.computerUseWelcome])
        let page = try #require(presenter.controller)
        var completed: Bool?
        let close = page.model.onEnd
        page.model.onEnd = { completed = $0; close?($0) }
        page.model.next()
        #expect(completed == true)
        #expect(source.enabledCount == 1, "Allow Access turns Computer Use on")
        #expect(page.model.followUp == .computerUse)
        #expect(shown() == [.computerUseWelcome, .computerUse], "the grant setup opens after the page closed")
        #expect(source.opened.isEmpty, "no System Settings pane opens before the setup asks")
        presenter.controller?.close()
    }

    @Test func notNowEndsThePageAndAsksForNothing() throws {
        let source = MockComputerUsePermissionSource(current: .none)
        let (presenter, shown) = presenter(source)
        presenter.showComputerUseAtFirstRun(isFirstRun: true, available: true, defaults: try defaults())
        let page = try #require(presenter.controller)
        page.model.skipStep()
        #expect(source.enabledCount == 0)
        #expect(source.opened.isEmpty)
        #expect(page.model.followUp == nil)
        #expect(shown() == [.computerUseWelcome])
        #expect(presenter.controller == nil)
    }

    /// After the Agents step: the page waits for that window to close, then opens once.
    @Test func thePageFollowsTheAgentsStepOnce() async throws {
        let (presenter, shown) = presenter()
        let store = try defaults()
        let agents = MockAgentSignInSource(agents: [OnboardingAgent(id: "codex", name: "Codex", brand: "openai", auth: .signedIn)])
        await presenter.showAgentsAtFirstRun(isFirstRun: true, source: agents, computerUse: true, defaults: store)
        await presenter.showAgentsAtFirstRun(isFirstRun: true, source: agents, computerUse: true, defaults: store)
        #expect(shown() == [.agents], "it waits for the Agents step")
        #expect(presenter.pendingFirstRun == [.computerUseWelcome])
        presenter.controller?.model.next()
        #expect(shown() == [.agents, .computerUseWelcome])
        presenter.controller?.model.skipStep()
        #expect(shown() == [.agents, .computerUseWelcome], "shown once")
        #expect(presenter.pendingFirstRun.isEmpty)
    }

    @Test func anUpgradeOrAPolicyLockNeverShowsThePage() async throws {
        let (upgrade, upgradeShown) = presenter()
        let upgraded = try defaults()
        upgrade.showComputerUseAtFirstRun(isFirstRun: false, available: true, defaults: upgraded)
        upgrade.showComputerUseAtFirstRun(isFirstRun: true, available: true, defaults: upgraded)
        #expect(upgradeShown().isEmpty, "an existing installation never gets it")

        let (locked, lockedShown) = presenter()
        locked.showComputerUseAtFirstRun(isFirstRun: true, available: false, defaults: try defaults())
        #expect(lockedShown().isEmpty, "Computer Use turned off by a managed policy: no page")

        // With no agent CLI the Agents step does not open, and the page opens at once.
        let (alone, aloneShown) = presenter()
        await alone.showAgentsAtFirstRun(isFirstRun: true, source: MockAgentSignInSource(), computerUse: true, defaults: try defaults())
        #expect(aloneShown() == [.computerUseWelcome])
        let (policy, policyShown) = presenter()
        await policy.showAgentsAtFirstRun(isFirstRun: true, source: MockAgentSignInSource(), computerUse: false, defaults: try defaults())
        #expect(policyShown().isEmpty)
    }

    /// The blue cursor tours through the motion gate; with Reduce Motion it rests on the first
    /// control and the picture still shows.
    @Test func theCursorToursOnlyWhileLoopsAreAllowed() {
        defer { Motion.reduceMotionOverride = nil }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: ComputerUseCursorIllustration.size),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let illustration = ComputerUseCursorIllustration()
        illustration.frame = NSRect(origin: .zero, size: ComputerUseCursorIllustration.size)
        window.contentView = illustration
        illustration.needsLayout = true
        illustration.layoutSubtreeIfNeeded()
        #expect(illustration.stops.count == 3)
        Motion.reduceMotionOverride = true
        illustration.updateTour()
        #expect(!illustration.isTouring, "Reduce Motion: the cursor rests")
        Motion.reduceMotionOverride = false
        illustration.updateTour()
        #expect(illustration.isTouring == Motion.cursor.animatesLoops, "the tour follows the cursor gate")
        #expect(illustration.accessibilityLabel() == OnboardingStrings.computerUseWelcomeIllustration)
    }

    @Test func theTourVisitsEveryStopAndLoopsWithoutAJump() throws {
        defer { Motion.reduceMotionOverride = nil }
        Motion.reduceMotionOverride = false
        let stops = [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 20), CGPoint(x: 90, y: 10)]
        guard let animation = Motion.cursor.cursorTourAnimation(stops: stops) as? CAKeyframeAnimation else {
            #expect(!Motion.cursor.animatesLoops, "no tour only when loops are off")
            return
        }
        let values = try #require(animation.values as? [NSValue]).map(\.pointValue)
        #expect(values.first == stops.last, "the loop starts where it ends")
        #expect(Set(values.map { "\($0.x),\($0.y)" }) == Set(stops.map { "\($0.x),\($0.y)" }))
        let times = try #require(animation.keyTimes).map(\.doubleValue)
        #expect(times == times.sorted() && times.first == 0 && (times.last ?? 2) <= 1)
        #expect(animation.repeatCount == .infinity)
        #expect(Motion.cursor.cursorTourAnimation(stops: [stops[0]]) == nil)
    }
}
