import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextOnboarding

/// Onboarding never replaces a theme the user already picked: not on the
/// first run, not on a rerun after an update, and not when the pick only
/// became known after the window opened (cmux.json loads asynchronously at
/// launch, and the user can pick a theme from the palette meanwhile).
@MainActor
@Suite struct ThemePickPersistenceTests {
    static let curated = [ThemeChoice(name: "Nord", input: .ghosttyDefault), ThemeChoice(name: "Vesper", input: .ghosttyDefault)]

    func services(pick: String?) -> MockOnboardingServices {
        let services = MockOnboardingServices()
        // cmux's default (Apple System) is the first choice.
        services.ghosttyHasOwnTheme = false
        services.selectedThemeName = pick
        services.themeChoices = Self.curated
        return services
    }

    func showTheme(_ model: OnboardingModel) async {
        model.stepDidAppear()
        for _ in 0..<200 where model.theme.choices.count < 2 { await Task.yield() }
    }

    @Test(arguments: [true, false])
    func continuingOrSkippingEveryStepKeepsAnExistingPick(_ completes: Bool) async {
        let services = services(pick: "Catppuccin Mocha")
        // First run, then a rerun (a version bump or the palette's "Show Onboarding").
        for _ in 0..<2 {
            let model = OnboardingModel(services: services, start: .theme)
            await showTheme(model)
            #expect(model.theme.selected == "Catppuccin Mocha")
            if completes { model.next() } else { model.skipStep() }
            model.finish(completed: completes)
        }
        #expect(services.appliedAppearance.isEmpty, "onboarding wrote \(services.appliedAppearance.map(\.0))")
        #expect(services.selectedThemeName == "Catppuccin Mocha")
    }

    /// A pick outside the curated list is offered (and shown as selected),
    /// not hidden behind the Apple System default.
    @Test func aPickOutsideTheCuratedListIsShownAsTheSelection() async {
        let model = OnboardingModel(services: services(pick: "Catppuccin Mocha"), start: .theme)
        await showTheme(model)
        #expect(model.theme.selectedChoice.name == "Catppuccin Mocha")
        #expect(model.theme.choices.compactMap(\.name).contains("Catppuccin Mocha"))
    }

    /// The window opened before cmux.json loaded (or the user picked a theme
    /// from the palette meanwhile): the theme step shows the pick, and Skip
    /// after trying another theme puts that pick back instead of removing it.
    @Test func aPickThatArrivesAfterTheWindowOpenedIsWhatSkipRestores() async {
        let services = services(pick: nil)
        let model = OnboardingModel(services: services, start: .theme)
        services.selectedThemeName = "Catppuccin Mocha"
        await showTheme(model)
        #expect(model.theme.selected == "Catppuccin Mocha")
        model.theme.select("Nord")
        #expect(services.selectedThemeName == "Nord")
        model.skipStep()
        #expect(services.selectedThemeName == "Catppuccin Mocha")

        let closing = OnboardingModel(services: services, start: .theme)
        services.selectedThemeName = "Vesper"
        await showTheme(closing)
        closing.theme.select("Nord")
        closing.finish(completed: false)
        #expect(services.selectedThemeName == "Vesper")
    }
}
