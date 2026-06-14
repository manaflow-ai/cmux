import Foundation
import Observation

/// User preference for whether the system keyboard's autocorrection, predictive
/// text, smart punctuation, and spell-checking are enabled in the mobile
/// terminal input field.
///
/// Terminals disable these traits by default because they mangle shell commands,
/// so the stored value defaults to `false` (everything off). When the user turns
/// it on, ``TerminalInputTextView`` applies the system-default traits so the
/// field behaves like an ordinary iOS text field — the Mail-style autocomplete
/// requested in issue #6083. Autocapitalization is intentionally *not* part of
/// this toggle and stays off regardless: capitalizing the first word of a command
/// is never wanted.
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
///     get: { TerminalKeyboardConfiguration.shared.autocorrectionEnabled },
///     set: { TerminalKeyboardConfiguration.shared.autocorrectionEnabled = $0 }
/// )) { Text("Autocorrection") }
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

    private static let autocorrectionEnabledKey = "cmux.terminal.keyboard.autocorrectionEnabled.v1"

    /// The store backing the persisted preference. `@ObservationIgnored` because
    /// the dependency itself never changes — only ``autocorrectionEnabled`` does.
    @ObservationIgnored private let defaults: UserDefaults

    /// Whether the system keyboard's autocorrection, predictive text, smart
    /// punctuation, and spell-checking are enabled in the terminal input field.
    ///
    /// Defaults to `false` (terminal-hardened: every assist trait off). Mutating
    /// it writes through to the injected ``UserDefaults`` and posts
    /// ``didChangeNotification`` so a live input view re-applies its traits.
    public var autocorrectionEnabled: Bool {
        didSet {
            guard autocorrectionEnabled != oldValue else { return }
            defaults.set(autocorrectionEnabled, forKey: Self.autocorrectionEnabledKey)
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
        self.autocorrectionEnabled = defaults.bool(forKey: Self.autocorrectionEnabledKey)
    }
}
