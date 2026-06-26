import Foundation
import Observation
import UIKit

/// Persisted iOS keyboard correction preference for the mobile terminal input.
///
/// Terminal command entry defaults to no autocorrection because system
/// corrections can change commands. Users who prefer the system predictive bar
/// can opt in from Settings; the terminal input proxy reads this object for its
/// ``UITextInputTraits`` and reloads the active keyboard when it changes.
@MainActor
@Observable
public final class MobileTerminalKeyboardCorrectionPreference {
    static let enabledDefaultsKey = "cmux.mobile.terminal.keyboardCorrectionsEnabled.v1"
    static let didChangeNotification = Notification.Name(
        "cmux.mobile.terminal.keyboardCorrectionsDidChange"
    )

    // UserDefaults is Apple-documented thread-safe; this type reads in init and
    // writes synchronously from the main actor.
    private nonisolated(unsafe) let defaults: UserDefaults

    /// Whether the terminal input enables iOS autocomplete, autocorrect, spell
    /// checking, and smart insert/delete traits. Defaults to `false`.
    public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledDefaultsKey)
            NotificationCenter.default.post(
                name: Self.didChangeNotification,
                object: self
            )
        }
    }

    /// Creates a preference store backed by `defaults`.
    /// - Parameter defaults: The store backing the persisted preference.
    ///   Defaults to `.standard`; tests pass a scoped suite. An absent key reads
    ///   as disabled without writing the default.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Self.enabledDefaultsKey)
    }

    var autocorrectionType: UITextAutocorrectionType { isEnabled ? .yes : .no }
    var spellCheckingType: UITextSpellCheckingType { isEnabled ? .yes : .no }
    var smartInsertDeleteType: UITextSmartInsertDeleteType { isEnabled ? .yes : .no }
}
