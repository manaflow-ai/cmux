// cmux server on this Mac (plans/cmux-next/server.md 3, 13, 14). DEV and
// NIGHTLY prototype: the menu bar item shows a projection of `server.status`.
// Scripts use the Rust CLI's `cmux server …` verbs, which the server role
// owns; these app actions only open or toggle the Mac's own UI, so their CLI
// surface is exempt. Titles live in ServerActions.xcstrings.

nonisolated enum ServerActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "server.makeThisMacAServer", title: t("action.server.makeThisMacAServer", "Make This Mac a Server"),
                keywords: ["server", "host", "self-host", "always on", "pair", "apps", "postgres"],
                category: .settings, symbol: "server.rack", surfaces: [.palette], isDebugOnly: true,
                surfacePlan: ActionSurfacePlan(cli: .exempt(.devOnly), contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "server.stopServing", title: t("action.server.stopServing", "Stop Serving"),
                keywords: ["server", "stop", "disable", "host"],
                category: .settings, symbol: "stop.circle", surfaces: [.palette], isDebugOnly: true,
                surfacePlan: ActionSurfacePlan(cli: .exempt(.devOnly), contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "server.showPanel", title: t("action.server.showPanel", "Server Status"),
                keywords: ["server", "status", "menu bar", "terminals", "apps", "database"],
                category: .settings, symbol: "server.rack", surfaces: [.palette], isDebugOnly: true,
                surfacePlan: ActionSurfacePlan(cli: .exempt(.devOnly), contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "server.showHealth", title: t("action.server.showHealth", "Server Health"),
                keywords: ["server", "health", "battery", "sleep", "disk", "lock", "internet"],
                category: .settings, symbol: "stethoscope", surfaces: [.palette], isDebugOnly: true,
                surfacePlan: ActionSurfacePlan(cli: .exempt(.devOnly), contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "server.addServer", title: t("action.server.addServer", "Add Server…"),
                keywords: ["server", "pair", "code", "approve", "add"],
                category: .settings, symbol: "plus.rectangle.on.rectangle", surfaces: [.palette], isDebugOnly: true,
                surfacePlan: ActionSurfacePlan(cli: .exempt(.devOnly), contextMenuExemption: .noObject)
            ),
        ]
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "ServerActions", bundle: .module)
    }
}
