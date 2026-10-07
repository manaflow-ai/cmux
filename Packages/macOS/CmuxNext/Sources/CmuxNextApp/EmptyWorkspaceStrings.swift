import Foundation

/// Localized copy for the empty workspace title.
enum EmptyWorkspaceStrings {
    static var title: String {
        String(localized: "emptyWorkspace.title", defaultValue: "Start something new", bundle: .module)
    }

}
