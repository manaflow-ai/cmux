public import CmuxNextDesign
import Foundation
public import Observation

/// Welcome step: theme and density, applied live so the whole app shows
/// the choice at once; Skip (or closing onboarding) puts the old ones back.
@MainActor
@Observable
public final class ThemeStepModel {
    public private(set) var choices: [ThemeChoice]
    /// Selected theme name; nil is the user's Ghostty theme.
    public private(set) var selected: String?
    public private(set) var density: Density
    @ObservationIgnored private let services: any OnboardingServices
    @ObservationIgnored private let originalTheme: String?
    @ObservationIgnored private let originalDensity: Density
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(services: any OnboardingServices) {
        self.services = services
        choices = [ThemeChoice(name: nil, input: services.ghosttyTheme)]
        selected = services.selectedThemeName
        originalTheme = services.selectedThemeName
        density = services.density
        originalDensity = services.density
    }

    /// Loads the curated themes once (theme files are read off the main thread).
    public func load() {
        guard loadTask == nil else { return }
        loadTask = Task { [weak self, services] in
            let loaded = await services.loadThemeChoices()
            guard let self else { return }
            choices = [choices[0]] + loaded.filter { $0.name != nil }
        }
    }

    public var selectedChoice: ThemeChoice {
        choices.first { $0.name == selected } ?? choices[0]
    }

    public func select(_ name: String?) {
        guard name != selected else { return }
        selected = name
        services.applyAppearance(themeName: name, density: density)
    }

    public func setDensity(_ value: Density) {
        guard value != density else { return }
        density = value
        services.applyAppearance(themeName: selected, density: value)
    }

    public var hasChanges: Bool { selected != originalTheme || density != originalDensity }

    /// Continue keeps what is applied.
    func commit() {}

    /// Skip puts back the theme and density from before onboarding.
    func revert() {
        guard hasChanges else { return }
        selected = originalTheme
        density = originalDensity
        services.applyAppearance(themeName: originalTheme, density: originalDensity)
    }
}
