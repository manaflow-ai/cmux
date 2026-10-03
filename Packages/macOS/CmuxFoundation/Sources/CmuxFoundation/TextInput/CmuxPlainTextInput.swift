public import AppKit

/// The one place cmux turns off macOS typing substitutions, so every text
/// editor saves exactly the characters that were typed
/// (https://github.com/manaflow-ai/cmux/issues/16738).
///
/// AppKit text views follow the macOS text input settings ("Use smart quotes
/// and dashes", text replacements, "Correct spelling automatically", "Add
/// period with double-space"), which are on by default. In cmux they rewrote
/// `"` into `“`/`”` and `--` into `—` in config files and commands, which
/// broke `.claude/settings.json` and crashed Claude Code.
///
/// Two layers cover every editor:
/// - ``NSTextView/cmuxDisableTypingSubstitutions()`` for each `NSTextView`
///   cmux creates. `scripts/lint-text-input-substitutions.py` fails when a new
///   one neither calls it nor sets `isEditable = false`.
/// - ``installAppDefaults(_:)`` at launch, for the text views AppKit and
///   SwiftUI create on their own: the field editor behind every `NSTextField`
///   and SwiftUI `TextField`, and SwiftUI `TextEditor`.
///
/// A user can still turn a substitution back on for one view from
/// Edit › Substitutions.
public struct CmuxPlainTextInput {
    private init() {}
    /// The `UserDefaults` keys AppKit reads when it creates a text view. The
    /// app's own domain takes precedence over the system-wide settings.
    public static let substitutionDefaultsKeys = [
        "NSAutomaticQuoteSubstitutionEnabled",
        "NSAutomaticDashSubstitutionEnabled",
        "NSAutomaticTextReplacementEnabled",
        "NSAutomaticSpellingCorrectionEnabled",
        "NSAutomaticPeriodSubstitutionEnabled",
        "NSAutomaticCapitalizationEnabled",
    ]

    /// Turns the substitutions off for text views created after this call.
    /// Call once at launch, before any window exists.
    public static func installAppDefaults(_ defaults: UserDefaults) {
        defaults.register(defaults: Dictionary(uniqueKeysWithValues: substitutionDefaultsKeys.map { ($0, false) }))
    }
}

extension NSTextView {
    /// Turns off every typing substitution on this text view. Call it on every
    /// editable `NSTextView` cmux creates, right after creating it. Period
    /// substitution and automatic capitalization have no per-view switch;
    /// ``CmuxPlainTextInput/installAppDefaults(_:)`` turns them off.
    public func cmuxDisableTypingSubstitutions() {
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
    }
}
