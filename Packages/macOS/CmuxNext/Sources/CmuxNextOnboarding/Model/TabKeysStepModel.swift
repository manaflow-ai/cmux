import Foundation
public import Observation

/// What Ctrl-1…9 select (R85, D4): tabs (the default, Spaces on
/// Ctrl-Opt-1…9) or Spaces (tabs on Ctrl-Opt-1…9). The App maps it to
/// `ShortcutDigitScheme`, which writes cmux.json `shortcuts.bindings`.
public enum TabKeysChoice: String, CaseIterable, Sendable {
    case tabs
    case spaces
}

/// The number keys step: the choice cmux.json is on, and the person's
/// pick. Continue writes a pick that differs; Skip and closing the window
/// write nothing.
@MainActor
@Observable
public final class TabKeysStepModel {
    /// The radio that is on; nil while loading, or when the person bound
    /// these keys by hand and has not picked.
    public private(set) var selected: TabKeysChoice?
    /// What cmux.json is on (nil: bound by hand), once loaded.
    public private(set) var current: TabKeysChoice?
    public private(set) var isLoaded = false
    @ObservationIgnored private let services: any OnboardingServices
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(services: any OnboardingServices) {
        self.services = services
    }

    /// Reads cmux.json once. A pick made before the read finishes stays.
    public func load() {
        guard loadTask == nil else { return }
        loadTask = Task { [weak self, services] in
            let current = await services.currentTabKeys()
            guard let self else { return }
            self.current = current
            isLoaded = true
            if selected == nil { selected = current }
        }
    }

    public func select(_ choice: TabKeysChoice) {
        selected = choice
    }

    /// Continue: writes the pick when it differs from what cmux.json is on.
    func commit() {}
}
