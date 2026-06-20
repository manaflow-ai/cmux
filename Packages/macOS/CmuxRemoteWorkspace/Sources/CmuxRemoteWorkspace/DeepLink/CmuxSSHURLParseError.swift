import Foundation

/// The reasons a `cmux://ssh` (or standard `ssh://`) deep link is rejected
/// before it can open a remote workspace.
///
/// Each case carries enough structured data for the app shell to render a
/// localized failure message; the package never localizes (see
/// ``CmuxSSHURLRequest`` for the parse contract).
public enum CmuxSSHURLParseError: Error, Equatable {
    /// The link did not include an SSH host.
    case missingDestination
    /// The resolved `user@host` destination exceeded `maxLength` characters.
    case destinationTooLong(maxLength: Int)
    /// The host or user contained control/format/hidden characters.
    case destinationContainsUnsafeCharacters
    /// The host or user began with a dash (would be parsed as an SSH flag).
    case destinationStartsWithDash
    /// The workspace title exceeded `maxLength` characters.
    case titleTooLong(maxLength: Int)
    /// The workspace title contained hidden control or formatting characters.
    case titleContainsUnsafeCharacters
    /// The port was outside 1...65535.
    case invalidPort
    /// An integer-typed SSH parameter (named by the payload) was not a valid
    /// bounded integer.
    case invalidIntegerParameter(String)
    /// The `host-key-policy` parameter (named by the payload) was not one of the
    /// accepted values.
    case invalidHostKeyPolicy(String)
    /// A boolean-typed parameter (named by the payload) was not a recognized
    /// boolean literal.
    case invalidBooleanParameter(String)
    /// The link mixed a path-style destination with query destination fields.
    case conflictingDestinationParameters
    /// The link supplied both `title` and `name`.
    case conflictingTitleParameters
    /// The link repeated a parameter (named by the payload).
    case duplicateParameter(String)
    /// The link included a parameter the SSH deep link does not support (named
    /// by the payload).
    case unsupportedParameter(String)
    /// More than one SSH link was opened at once.
    case multipleLinks
}
