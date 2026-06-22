import Foundation

/// Settings under the dotted-id prefix `performance.*`.
public struct PerformanceCatalogSection: SettingCatalogSection {
    public let diagnosticsEnabled = DefaultsKey<Bool>(
        id: "performance.diagnostics.enabled",
        defaultValue: false,
        userDefaultsKey: "performance.diagnostics.enabled"
    )

    public let diagnosticsIntervalSeconds = DefaultsKey<Double>(
        id: "performance.diagnostics.intervalSeconds",
        defaultValue: 5,
        userDefaultsKey: "performance.diagnostics.intervalSeconds"
    )

    public let diagnosticsVerboseEventsEnabled = DefaultsKey<Bool>(
        id: "performance.diagnostics.verboseEvents.enabled",
        defaultValue: false,
        userDefaultsKey: "performance.diagnostics.verboseEvents.enabled"
    )

    public let diagnosticsSignpostsEnabled = DefaultsKey<Bool>(
        id: "performance.diagnostics.signposts.enabled",
        defaultValue: true,
        userDefaultsKey: "performance.diagnostics.signposts.enabled"
    )

    public let diagnosticsJSONDumpEnabled = DefaultsKey<Bool>(
        id: "performance.diagnostics.jsonDump.enabled",
        defaultValue: false,
        userDefaultsKey: "performance.diagnostics.jsonDump.enabled"
    )

    public let diagnosticsJSONDumpPath = DefaultsKey<String>(
        id: "performance.diagnostics.jsonDump.path",
        defaultValue: "",
        userDefaultsKey: "performance.diagnostics.jsonDump.path"
    )

    public let diagnosticsTitleScopeEnabled = DefaultsKey<Bool>(
        id: "performance.diagnostics.scopes.title",
        defaultValue: true,
        userDefaultsKey: "performance.diagnostics.scopes.title"
    )

    public let diagnosticsSidebarScopeEnabled = DefaultsKey<Bool>(
        id: "performance.diagnostics.scopes.sidebar",
        defaultValue: true,
        userDefaultsKey: "performance.diagnostics.scopes.sidebar"
    )

    public let diagnosticsMobileScopeEnabled = DefaultsKey<Bool>(
        id: "performance.diagnostics.scopes.mobile",
        defaultValue: true,
        userDefaultsKey: "performance.diagnostics.scopes.mobile"
    )

    public let diagnosticsRendererScopeEnabled = DefaultsKey<Bool>(
        id: "performance.diagnostics.scopes.renderer",
        defaultValue: true,
        userDefaultsKey: "performance.diagnostics.scopes.renderer"
    )

    public init() {}
}
