import Foundation

/// Errors thrown while decoding a hook definition.
public enum CmuxHookDefinitionDecodingError: Error, Sendable, Equatable {
    /// The hook's `command` property was blank or whitespace-only.
    case blankCommand
}
