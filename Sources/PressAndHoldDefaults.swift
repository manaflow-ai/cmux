import Foundation

/// Controls the macOS "press and hold" accent-character popup for cmux.
///
/// Holding a key (for example `l` while navigating with vim motions) should
/// repeat the key into the terminal, but macOS instead pops up the
/// alternate-character picker unless the app opts out. Like Ghostty, cmux opts
/// out at launch. See https://github.com/manaflow-ai/cmux/issues/5457.
///
/// Constructed with the `UserDefaults` it registers into, so callers and tests
/// inject the target domain instead of reaching for ambient global state.
struct PressAndHoldDefaults {
    /// The user-default key macOS reads to decide between repeating a held key
    /// and showing the accent-character popup.
    static let pressAndHoldEnabledKey = "ApplePressAndHoldEnabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Disables the press-and-hold accent popup so held keys repeat into the
    /// terminal.
    func registerDisabled() {
        // Register the disabled value in the registration domain (the
        // lowest-priority source), mirroring Ghostty/VS Code/iTerm. This
        // provides cmux's per-app default without clobbering an explicit
        // global override a user may have set via
        // `defaults write -g ApplePressAndHoldEnabled -bool true`.
        defaults.register(defaults: [Self.pressAndHoldEnabledKey: false])
    }
}
