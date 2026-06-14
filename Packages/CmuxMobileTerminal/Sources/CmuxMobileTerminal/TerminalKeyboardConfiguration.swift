import Foundation
import Observation

/// User preference for whether the system keyboard's inline autocomplete
/// predictions are enabled in the mobile terminal input field.
///
/// Terminals keep replacement-based traits off because they can rewrite shell
/// commands after bytes have already been sent. The stored value defaults to
/// `false`; when the user turns it on, ``TerminalInputTextView`` enables
/// `inlinePredictionType` so the keyboard can show append-style autocomplete
/// suggestions without enabling autocorrection, smart punctuation, or spell
/// checking replacements. Autocapitalization is intentionally *not* part of this
/// toggle and stays off regardless: capitalizing the first word of a command is
/// never wanted.
///
/// Mirrors ``TerminalAccessoryConfiguration``: a `@MainActor` `@Observable` store
/// persisted to `UserDefaults` that posts ``didChangeNotification`` so the
/// off-limits UIKit input view can re-apply its keyboard traits live. It is the
/// single source of truth for that preference, read by the input view and bound
/// by the settings toggle.
///
/// ```swift
/// // Settings toggle binding:
/// Toggle(isOn: Binding(
///     get: { TerminalKeyboardConfiguration.shared.autocompleteEnabled },
///     set: { TerminalKeyboardConfiguration.shared.autocompleteEnabled = $0 }
/// )) { Text("Autocomplete") }
/// ```
@MainActor
@Observable
public final class TerminalKeyboardConfiguration {
    /// Shared instance backing the live input field and the settings toggle.
    ///
    /// Read from the UIKit input view in the off-limits typing-latency path
    /// (``TerminalInputTextView``) and bound by the mobile settings toggle.
    /// TRANSITIONAL — retires with ``TerminalAccessoryConfiguration/shared`` once
    /// construction-at-root injection lands in the GhosttySurfaceView split.
    public static let shared = TerminalKeyboardConfiguration()

    /// Posted (on the main thread) whenever the preference changes, so the UIKit
    /// terminal input view can re-apply its keyboard traits and reload the live
    /// keyboard.
    public static let didChangeNotification = Notification.Name("cmux.terminal.keyboardConfigurationDidChange")

    private static let autocompleteEnabledKey = "cmux.terminal.keyboard.autocompleteEnabled.v1"

    /// The store backing the persisted preference. `@ObservationIgnored` because
    /// the dependency itself never changes — only ``autocompleteEnabled`` does.
    @ObservationIgnored private let defaults: UserDefaults

    /// Whether the system keyboard's inline autocomplete predictions are enabled
    /// in the terminal input field.
    ///
    /// Defaults to `false` (terminal-hardened: inline predictions off). Mutating
    /// it writes through to the injected ``UserDefaults`` and posts
    /// ``didChangeNotification`` so a live input view re-applies its traits.
    public var autocompleteEnabled: Bool {
        didSet {
            guard autocompleteEnabled != oldValue else { return }
            defaults.set(autocompleteEnabled, forKey: Self.autocompleteEnabledKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// Creates a configuration backed by `defaults`.
    ///
    /// - Parameter defaults: The `UserDefaults` store to read and persist the
    ///   preference from. Defaults to `.standard` for the live ``shared``
    ///   instance; tests inject a suite-scoped store so they exercise the
    ///   persistence round-trip without touching the user's real settings. An
    ///   absent key reads as `false` (the terminal-hardened default) without a
    ///   write.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.autocompleteEnabled = defaults.bool(forKey: Self.autocompleteEnabledKey)
    }
}
