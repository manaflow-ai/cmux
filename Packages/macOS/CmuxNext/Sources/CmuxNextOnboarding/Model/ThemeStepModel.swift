public import CmuxNextDesign
import Foundation
public import Observation

/// Theme step: a Ghostty theme, applied live so the whole app shows the
/// choice at once; Skip (or closing onboarding) puts the old one back.
@MainActor
@Observable
public final class ThemeStepModel {
    public private(set) var choices: [ThemeChoice]
    /// Selected theme name; nil is the user's Ghostty theme.
    public private(set) var selected: String?
    public private(set) var density: Density
    @ObservationIgnored private let services: any OnboardingServices
    /// The theme and density before this step changed anything, read at
    /// its first change rather than when the window opened: cmux.json may
    /// load, or the user pick a theme elsewhere, in between, and Skip must
    /// put back that pick, not remove it.
    @ObservationIgnored private var original: (theme: String?, density: Density)?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(services: any OnboardingServices) {
        self.services = services
        // No theme of the user's own: the first choice is cmux's default,
        // Apple System Colors following the macOS appearance.
        choices = [ThemeChoice(name: nil, input: services.ghosttyTheme,
                               label: services.ghosttyHasOwnTheme ? nil : OnboardingStrings.appleSystemTheme)]
        selected = services.selectedThemeName
        density = services.density
    }

    /// Loads the curated themes once (theme files are read off the main
    /// thread). Until this step changes something it shows the pick in
    /// effect now, offered as a choice when it is not a curated one.
    public func load() {
        refreshFromSettings()
        guard loadTask == nil else { return }
        loadTask = Task { [weak self, services] in
            let loaded = await services.loadThemeChoices()
            guard let self else { return }
            choices = [choices[0]] + loaded.filter { $0.name != nil }
            refreshFromSettings()
            // The current colors are the pick's (cmux.json applies it).
            if let selected, !choices.contains(where: { $0.name == selected }) {
                choices.append(ThemeChoice(name: selected, input: services.ghosttyTheme))
            }
        }
    }

    private func refreshFromSettings() {
        guard original == nil else { return }
        selected = services.selectedThemeName
        density = services.density
    }

    private func recordOriginal() {
        guard original == nil else { return }
        original = (services.selectedThemeName, services.density)
    }

    public var selectedChoice: ThemeChoice {
        choices.first { $0.name == selected } ?? choices[0]
    }

    public func select(_ name: String?) {
        guard name != selected else { return }
        recordOriginal()
        selected = name
        services.applyAppearance(themeName: name, density: density)
    }

    public func setDensity(_ value: Density) {
        guard value != density else { return }
        recordOriginal()
        density = value
        services.applyAppearance(themeName: selected, density: value)
    }

    public var hasChanges: Bool { original.map { selected != $0.theme || density != $0.density } ?? false }
    /// Set by Continue on the welcome step: closing onboarding later keeps the pick.
    public private(set) var isCommitted = false

    /// Continue keeps what is applied.
    func commit() { isCommitted = true }

    /// Skip puts back the theme and density from before onboarding.
    func revert() {
        isCommitted = false
        guard let original, hasChanges else { return }
        selected = original.theme
        density = original.density
        services.applyAppearance(themeName: original.theme, density: original.density)
    }
}
