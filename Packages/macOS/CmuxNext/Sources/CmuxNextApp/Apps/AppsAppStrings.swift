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
    /// An app tab whose app the registry has not listed yet (launch scan).
    static var tabLoading: String { String(localized: "apps.tab.loading", defaultValue: "Loading the app…", table: "Handlers", bundle: .module) }
    /// An app tab whose app is not installed, is turned off, or has no page.
    static var tabUnavailable: String {
        String(localized: "apps.tab.unavailable", defaultValue: "This app is not installed or has no page", table: "Handlers", bundle: .module)
    }
    static var run: String { String(localized: "apps.commands.run", defaultValue: "Run", table: "Handlers", bundle: .module) }
}
