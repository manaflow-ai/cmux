import Foundation

/// Localized copy for the actions shown when a workspace has no panes.
enum EmptyWorkspaceStrings {
    static var title: String {
        String(localized: "emptyWorkspace.title", defaultValue: "Start something new", bundle: .module)
    }

    static var subtitle: String {
        String(localized: "emptyWorkspace.subtitle", defaultValue: "Open a new tab or bring your existing work into cmux.", bundle: .module)
    }

    static var new: String {
        String(localized: "emptyWorkspace.new", defaultValue: "New", bundle: .module)
    }

    static var importAndSync: String {
        String(localized: "emptyWorkspace.importAndSync", defaultValue: "Import and sync", bundle: .module)
    }
}
