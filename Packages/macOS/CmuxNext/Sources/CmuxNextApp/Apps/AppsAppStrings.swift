import Foundation

/// App-platform strings of the App target (Resources/Handlers.xcstrings).
nonisolated enum AppsAppStrings {
    static var commandsTitle: String { String(localized: "apps.commands.title", defaultValue: "App Commands", table: "Handlers", bundle: .module) }
    static var commandsPlaceholder: String {
        String(localized: "apps.commands.placeholder", defaultValue: "Search app commands", table: "Handlers", bundle: .module)
    }
    static var run: String { String(localized: "apps.commands.run", defaultValue: "Run", table: "Handlers", bundle: .module) }
}
