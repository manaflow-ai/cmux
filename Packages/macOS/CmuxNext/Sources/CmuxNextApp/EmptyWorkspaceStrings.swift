import Foundation

/// Localized copy for the empty workspace title.
enum EmptyWorkspaceStrings {
    static var title: String {
        String(localized: "emptyWorkspace.title", defaultValue: "Start something new", bundle: .module)
    }

    /// The empty state's line when the first terminal did not start.
    static func failed(_ reason: String) -> String {
        String(format: String(localized: "emptyWorkspace.failed",
                              defaultValue: "The terminal did not start: %@\nPress Return to try again.", bundle: .module), reason)
    }

}
