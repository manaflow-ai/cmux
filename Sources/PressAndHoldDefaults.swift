import Foundation

/// Controls the macOS "press and hold" accent-character popup for cmux.
///
/// Holding a key (for example `l` while navigating with vim motions) should
/// repeat the key into the terminal, but macOS instead pops up the
/// alternate-character picker unless the app opts out. Like Ghostty, cmux opts
/// out at launch. See https://github.com/manaflow-ai/cmux/issues/5457.
enum PressAndHoldDefaults {
    /// The user-default key macOS reads to decide between repeating a held key
    /// and showing the accent-character popup.
    static let pressAndHoldEnabledKey = "ApplePressAndHoldEnabled"

    /// Disables the press-and-hold accent popup so held keys repeat into the
    /// terminal. Pure with respect to the injected `defaults`, so it is
    /// unit-testable against a scratch `UserDefaults(suiteName:)`.
    static func registerDisabled(defaults: UserDefaults = .standard) {
        // Register the disabled value in the registration domain (the
        // lowest-priority source), mirroring Ghostty/VS Code/iTerm. This
        // provides cmux's per-app default without clobbering an explicit
        // global override a user may have set via
        // `defaults write -g ApplePressAndHoldEnabled -bool true`.
        defaults.register(defaults: [pressAndHoldEnabledKey: false])
    }
}
