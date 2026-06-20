import Foundation

/// The reasons a `cmux://prompt` / `cmux://rules` text deep link is rejected.
public enum CmuxTextURLParseError: Error, Equatable {
    /// The link did not include text.
    case missingText
    /// The text exceeded `maxLength` characters.
    case textTooLong(maxLength: Int)
    /// The text contained control/format/hidden characters.
    case textContainsUnsafeCharacters
    /// The name exceeded `maxLength` characters.
    case nameTooLong(maxLength: Int)
    /// The name contained hidden control or formatting characters.
    case nameContainsUnsafeCharacters
    /// The title exceeded `maxLength` characters.
    case titleTooLong(maxLength: Int)
    /// The title contained hidden control or formatting characters.
    case titleContainsUnsafeCharacters
    /// A boolean-typed parameter (named by the payload) was not a recognized
    /// boolean literal.
    case invalidBooleanParameter(String)
    /// The link repeated a parameter (named by the payload).
    case duplicateParameter(String)
    /// The link included a parameter the text deep link does not support (named
    /// by the payload).
    case unsupportedParameter(String)
    /// More than one cmux external link was opened at once.
    case multipleLinks
}
