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
    static var run: String { String(localized: "apps.commands.run", defaultValue: "Run", table: "Handlers", bundle: .module) }
    /// "Hide CodeRouter" / "Show CodeRouter".
    static func hide(_ app: String) -> String {
        String(format: String(localized: "apps.hide.format", defaultValue: "Hide %@", table: "Handlers", bundle: .module), app)
    }
    static func show(_ app: String) -> String {
        String(format: String(localized: "apps.show.format", defaultValue: "Show %@", table: "Handlers", bundle: .module), app)
    }
    static var shown: String { String(localized: "apps.shown", defaultValue: "Shown", table: "Handlers", bundle: .module) }
    static var hidden: String { String(localized: "apps.hidden", defaultValue: "Hidden", table: "Handlers", bundle: .module) }
    static var hideTitle: String { String(localized: "apps.visibility.hideTitle", defaultValue: "Hide App", table: "Handlers", bundle: .module) }
    static var showTitle: String {
        String(localized: "apps.visibility.showTitle", defaultValue: "Show Hidden Apps", table: "Handlers", bundle: .module)
    }
    static var visibilityPlaceholder: String {
        String(localized: "apps.visibility.placeholder", defaultValue: "Search apps", table: "Handlers", bundle: .module)
    }
}
