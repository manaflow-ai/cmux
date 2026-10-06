// cmux server on this Mac (plans/cmux-next/server.md 3, 13, 14). DEV and
// NIGHTLY prototype: the menu bar item shows a projection of `server.status`.
// Add Server… and Server Status are in every build, in the Server menu: they
// pair a remote server (a Chief brain, brains/DESIGN-cmux-lawrence.md) and
// show where the user's Chief runs.
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
                id: "server.addServer", title: t("action.server.addServer", "Add Server…"),
                keywords: ["server", "pair", "code", "approve", "add", "chief", "always on"],
                category: .settings, symbol: "plus.rectangle.on.rectangle", surfaces: [.palette, .menu], mainMenu: .server,
                // `cmux servers add CODE` (server.pair.approve) is the owner's verb.
                surfacePlan: ActionSurfacePlan(cli: .exempt(.ownerVerb), contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "server.showPanel", title: t("action.server.showPanel", "Server Status"),
                keywords: ["server", "status", "menu bar", "terminals", "apps", "database", "chief"],
                category: .settings, symbol: "server.rack", surfaces: [.palette, .menu], mainMenu: .server,
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "server.showHealth", title: t("action.server.showHealth", "Server Health"),
                keywords: ["server", "health", "battery", "sleep", "disk", "lock", "internet"],
                category: .settings, symbol: "stethoscope", surfaces: [.palette], isDebugOnly: true,
                surfacePlan: ActionSurfacePlan(cli: .exempt(.devOnly), contextMenuExemption: .noObject)
            ),
        ]
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "ServerActions", bundle: .module)
    }
}
