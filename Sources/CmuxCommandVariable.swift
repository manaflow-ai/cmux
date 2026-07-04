import Foundation

/// A `{{name}}` (or `{{name=default}}`) placeholder discovered in a custom
/// command's `command` string.
///
/// Variables let a single `commands` entry be reused with different values:
/// cmux prompts for each variable before running the command and substitutes
/// the entered values back into the shell string. The syntax intentionally
/// matches the existing `{{…}}` convention already used by Vault agent
/// templates so users only have to learn one placeholder form.
///
/// See ``CmuxCommandTemplate`` for the parsing and substitution logic.
struct CmuxCommandVariable: Equatable, Sendable {
    /// The placeholder name, e.g. `environment` for `{{environment}}`.
    let name: String
    /// The optional default value parsed from `{{name=default}}`, used to
    /// pre-fill the prompt field. `nil` when the placeholder has no default.
    let defaultValue: String?
}
