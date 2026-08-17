public import CMUXMobileCore
public import Foundation
public import Observation

/// Persists the rendering preference for each Mac browser panel.
@MainActor
@Observable
public final class BrowserPresentationModeStore {
    private let defaults: UserDefaults
    private let keyPrefix: String

    /// Creates a mode store.
    /// - Parameters:
    ///   - defaults: The persistence domain. Inject a suite in tests.
    ///   - keyPrefix: A namespace for the panel preferences.
    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "cmux.mobile.browser.presentation"
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    /// Returns the saved mode, defaulting to Mac streaming.
    public func mode(for panelID: String) -> MobileBrowserPresentationMode {
        guard let rawValue = defaults.string(forKey: key(for: panelID)),
              let mode = MobileBrowserPresentationMode(rawValue: rawValue) else {
            return .stream
        }
        return mode
    }

    /// Saves a mode for one panel.
    public func setMode(_ mode: MobileBrowserPresentationMode, for panelID: String) {
        defaults.set(mode.rawValue, forKey: key(for: panelID))
    }

    /// Removes the saved preference for one panel.
    public func removeMode(for panelID: String) {
        defaults.removeObject(forKey: key(for: panelID))
    }

    private func key(for panelID: String) -> String {
        "\(keyPrefix).\(panelID)"
    }
}
