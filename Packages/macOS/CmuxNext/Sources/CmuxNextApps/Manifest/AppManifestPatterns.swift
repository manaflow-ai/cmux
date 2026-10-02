import Foundation

/// The patterns of `cmux-app.schema.json`, compiled once.
nonisolated enum AppManifestPatterns {
    static let appID = regex(#"^(local|[a-z0-9](?:[a-z0-9-]{0,38}))/[a-z0-9][a-z0-9-]{0,63}$"#)
    static let semver = regex(#"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"#)
    static let httpsURL = regex(#"^https://"#)
    static let repository = regex(#"^https://github\.com/[A-Za-z0-9-]+/[A-Za-z0-9._-]+$"#)
    static let relativePath = regex(#"^(?!/)(?!.*(?:^|/)\.\.(?:/|$))[A-Za-z0-9._/@-]+$"#)
    static let contributionID = regex(#"^[a-z][a-zA-Z0-9-]{0,63}$"#)
    static let exportName = regex(#"^[A-Za-z_$][A-Za-z0-9_$]{0,63}$"#)
    static let symbol = regex(#"^[a-z0-9.]{1,64}$"#)
    static let language = regex(#"^[a-z]{2}(?:-[A-Za-z]{2,4})?$"#)
    static let scope = regex(#"^([a-z][a-z0-9_-]{0,31}:(read|write|execute|external|run|post|input|control|expose|synced)|net:(\*\.)?[a-z0-9.-]{1,253}|integration:[a-z0-9-]{1,32}(:read)?|clipboard:write)$"#)
    static let activation = regex(#"^(onStartup|onSidebarSection:[a-z][a-zA-Z0-9-]{0,63}|onStatusItem:[a-z][a-zA-Z0-9-]{0,63}|onCommand:[a-z][a-zA-Z0-9-]{0,63}|onPane:[a-z][a-zA-Z0-9-]{0,63}|onPaletteScope:[a-z][a-zA-Z0-9-]{0,63}|onEvent:[a-z][a-z0-9_.-]{0,95})$"#)
    static let commandContext = regex(#"^(palette|sidebarBackground|workspaceRow|tab|sidebarSection:[a-z][a-zA-Z0-9-]{0,63}|statusItem:[a-z][a-zA-Z0-9-]{0,63})$"#)
    static let palettePrefix = regex(#"^[\p{P}\p{S}]$"#)
    static let nativeView = regex(#"^[a-z][a-zA-Z0-9.-]{0,63}$"#)
    static let mcpGroup = regex(#"^[a-z][a-z0-9_-]{0,31}$"#)
    static let eventName = regex(#"^[a-z][a-z0-9_.-]{0,95}$"#)
    static let binaryName = regex(#"^[a-z0-9][a-z0-9-]{0,63}$"#)
    static let hexColor = regex(#"^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$"#)

    static let categories: Set<String> = ["sidebar", "agents", "git", "productivity", "monitoring", "themes", "browser", "cloud",
                                          "developer-tools", "fun"]

    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are literals; a failure here is a programming error caught by the tests.
        (try? NSRegularExpression(pattern: pattern)) ?? NSRegularExpression()
    }
}
