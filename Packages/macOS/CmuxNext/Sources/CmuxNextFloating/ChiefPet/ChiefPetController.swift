public import AppKit
import CmuxNextCompat
import CmuxNextDesign

/// Owns the Chief pet's panel: shown while it is turned on, made on first
/// show and kept (with its spot) while hidden.
@MainActor
public final class ChiefPetController {
    private let enabled: @MainActor @Sendable () -> Bool
    private let makePanel: () -> ChiefPetPanel
    /// What a click on the pet opens.
    private let onClick: () -> Void
    private(set) var panel: ChiefPetPanel?
    private var watch: Task<Void, Never>?

    /// `enabled`: whether the pet shows, read under observation; nil reads `ChiefPetTunables.enabled`.
    public init(enabled: (@MainActor @Sendable () -> Bool)? = nil,
                makePanel: @escaping () -> ChiefPetPanel,
                onClick: @escaping () -> Void) {
        self.enabled = enabled ?? { ChiefPetTunables.enabled.value }
        self.makePanel = makePanel
        self.onClick = onClick
    }

    var isShown: Bool { panel?.isVisible == true }

    /// Follows the switch: shows the pet when it turns on, hides it when it turns off.
    public func start() {
        // task-owner: lives as long as the app services; event-driven (Observation)
        watch = Task { [weak self, enabled] in
            for await on in ObservationStream({ enabled() }) {
                self?.sync(on)
            }
        }
    }

    func sync(_ on: Bool) {
        if on {
            panelOnce().present()
        } else {
            panel?.dismiss()
        }
    }

    private func panelOnce() -> ChiefPetPanel {
        if let panel { return panel }
        let made = makePanel()
        made.onClick = { [weak self] in self?.onClick() }
        made.onExpand = { [weak self] in self?.onClick() }
        panel = made
        return made
    }
}
