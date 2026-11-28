import Foundation

/// App-platform strings of the App target (Resources/Handlers.xcstrings).
nonisolated enum AppsAppStrings {
    static var commandsTitle: String { String(localized: "apps.commands.title", defaultValue: "App Commands", table: "Handlers", bundle: .module) }
    static var commandsPlaceholder: String {
        String(localized: "apps.commands.placeholder", defaultValue: "Search app commands", table: "Handlers", bundle: .module)
    }
    /// "Open CodeRouter".
    static func open(_ app: String) -> String {
        String(format: String(localized: "apps.open.format", defaultValue: "Open %@", table: "Handlers", bundle: .module), app)
    }
    static var mountFailed: String { String(localized: "apps.mount.failed", defaultValue: "The app could not start", table: "Handlers", bundle: .module) }
    static var noRecord: String {
        String(localized: "apps.set.noRecord", defaultValue: "cmux-tui answered without the app's state", table: "Handlers", bundle: .module)
    }
    static var run: String { String(localized: "apps.commands.run", defaultValue: "Run", table: "Handlers", bundle: .module) }
}
