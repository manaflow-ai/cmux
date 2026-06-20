import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// User preference for whether the system keyboard's autocomplete and
/// correction traits are enabled in the mobile terminal input field.
///
/// The stored value defaults to `false`, preserving terminal-hardened input
/// where UIKit cannot rewrite shell commands. When the user turns it on,
/// ``TerminalInputTextView`` restores autocomplete, autocorrection, smart
/// punctuation, smart insert/delete, and spell-checking traits to their system
/// defaults. Autocapitalization is intentionally *not* part of this toggle and
/// stays off regardless: capitalizing the first word of a command is never
/// wanted.
///
/// Mirrors ``TerminalAccessoryConfiguration``'s persistence contract without
/// exposing global runtime state: the app composition root owns one instance and
/// injects it into both Settings and the live terminal surface. The store is
/// persisted to `UserDefaults` and posts ``didChangeNotification`` so the UIKit
/// input view can re-apply its keyboard traits live.
///
/// ```swift
/// let configuration = TerminalKeyboardConfiguration()
/// let surface = GhosttySurfaceView(
///     runtime: runtime,
///     delegate: delegate,
///     keyboardConfiguration: configuration
/// )
/// ```
@MainActor
@Observable
public final class TerminalKeyboardConfiguration {
    /// Posted (on the main thread) whenever the preference changes, so the UIKit
    /// terminal input view can re-apply its keyboard traits and reload the live
    /// keyboard.
    public static let didChangeNotification = Notification.Name("cmux.terminal.keyboardConfigurationDidChange")

    private static let autocompleteEnabledKey = "cmux.terminal.keyboard.autocompleteEnabled.v1"

    /// The store backing the persisted preference. `@ObservationIgnored` because
    /// the dependency itself never changes — only ``autocompleteEnabled`` does.
    @ObservationIgnored private let defaults: UserDefaults

    /// Whether the system keyboard's autocomplete and correction traits are
    /// enabled in the terminal input field.
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

    #if canImport(UIKit)
    /// The UIKit inline-prediction trait represented by the current preference.
    ///
    /// `true` maps to `.default`, not `.yes`, so the app-level setting respects
    /// the user's global keyboard settings once terminal hardening is disabled.
    public var inlinePredictionType: UITextInlinePredictionType {
        Self.inlinePredictionType(autocompleteEnabled: autocompleteEnabled)
    }

    /// Returns the UIKit inline-prediction trait for a stored preference value.
    ///
    /// - Parameter autocompleteEnabled: Whether the user enabled terminal
    ///   autocomplete and correction traits.
    /// - Returns: `.default` when enabled and `.no` when disabled.
    public static func inlinePredictionType(autocompleteEnabled: Bool) -> UITextInlinePredictionType {
        autocompleteEnabled ? .default : .no
    }
    #endif

    /// Creates a configuration backed by `defaults`.
    ///
    /// - Parameter defaults: The `UserDefaults` store to read and persist the
    ///   preference from. Defaults to `.standard` for the app-root instance;
    ///   tests inject a suite-scoped store so they exercise the persistence
    ///   round-trip without touching the user's real settings. An absent key
    ///   reads as `false` (the terminal-hardened default) without a write.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.autocompleteEnabled = defaults.bool(forKey: Self.autocompleteEnabledKey)
    }
}
