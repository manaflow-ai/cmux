import CmuxNextActions
import Foundation

/// Where `cmux window|pane|tab screenshot` puts the PNG: its `out` argument.
/// Not implemented yet: every value gives a temporary file.
enum ScreenshotOutput: Equatable {
    case file(URL)
    case inline
    case temporary

    init(_ invocation: ActionInvocation) throws {
        self = .temporary
    }

    init(out text: String, isDirectory: (String) -> Bool) throws {
        self = .temporary
    }
}
