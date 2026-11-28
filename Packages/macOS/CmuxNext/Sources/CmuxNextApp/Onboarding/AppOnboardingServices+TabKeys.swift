import CmuxNextOnboarding
import CmuxNextSettings

/// The number keys step (D4) over cmux.json: `ShortcutDigitScheme` is the
/// one writer of the Ctrl-1…9 bindings, as Base Keymap is for presets.
extension AppOnboardingServices {
    var offersTabKeys: Bool { services.settings != nil }

    /// Read from the file, not the snapshot, so a write the watcher has
    /// not reloaded yet counts.
    func currentTabKeys() async -> TabKeysChoice? {
        guard let settings = services.settings, let scheme = try? await settings.digitScheme() else { return nil }
        return Self.choice(scheme)
    }

    /// Queued behind onboarding's other cmux.json writes (`lastWrite`). The
    /// file watcher applies it to the registry, as for a hand edit.
    func applyTabKeys(_ choice: TabKeysChoice) {
        guard let settings = services.settings else { return }
        let previous = lastWrite
        let registry = services.registry
        lastWrite = Task {
            await previous?.value
            do {
                try await settings.applyDigitScheme(Self.scheme(choice))
            } catch {
                registry.refuse(String(describing: error))
            }
        }
    }

    static func scheme(_ choice: TabKeysChoice) -> ShortcutDigitScheme {
        switch choice {
        case .tabs: .tabs
        case .spaces: .spaces
        }
    }

    static func choice(_ scheme: ShortcutDigitScheme) -> TabKeysChoice {
        switch scheme {
        case .tabs: .tabs
        case .spaces: .spaces
        }
    }
}
