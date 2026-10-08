import Foundation
import Observation
import UIKit

/// Persisted control for iOS keyboard corrections in the mobile terminal.
///
/// Terminal input defaults to literal text because autocorrection can change a
/// valid command. Users who want system suggestions can opt in from Settings.
@MainActor
@Observable
public final class MobileTerminalKeyboardCorrectionPreference {
    static let enabledDefaultsKey = "cmux.mobile.terminal.keyboardCorrectionsEnabled.v1"
    static let didChangeNotification = Notification.Name(
        "cmux.mobile.terminal.keyboardCorrectionsDidChange"
    )

    // UserDefaults is documented as thread-safe; this store is read and written
    // on the main actor, while the injected value is immutable after init.
    private nonisolated(unsafe) let defaults: UserDefaults

    /// Whether the terminal input enables iOS keyboard corrections and
    /// predictive suggestions. Defaults to `false` for command safety.
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

    /// Creates a preference backed by `defaults`.
    /// - Parameter defaults: The store used for persistence. Tests pass a
    ///   suite-scoped store; an absent value remains disabled without a write.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Self.enabledDefaultsKey)
    }

    var autocorrectionType: UITextAutocorrectionType { isEnabled ? .yes : .no }
    var spellCheckingType: UITextSpellCheckingType { isEnabled ? .yes : .no }
    var smartInsertDeleteType: UITextSmartInsertDeleteType { isEnabled ? .yes : .no }
    var inlinePredictionType: UITextInlinePredictionType { isEnabled ? .yes : .no }
}
