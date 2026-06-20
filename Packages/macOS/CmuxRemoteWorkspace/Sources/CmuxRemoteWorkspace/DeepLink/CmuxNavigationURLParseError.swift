import Foundation

/// The reasons a `cmux://workspace/...` navigation deep link is rejected.
public enum CmuxNavigationURLParseError: Error, Equatable {
    /// The URL did not match the supported `workspace/<id>[/pane|surface/<id>]`
    /// shape.
    case unsupportedURLShape
    /// A path identifier (named by the payload, e.g. `workspace`/`pane`/`surface`)
    /// was not a valid UUID.
    case invalidIdentifier(String)
}
