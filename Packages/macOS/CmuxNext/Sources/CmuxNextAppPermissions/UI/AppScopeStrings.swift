import Foundation

/// The consent copy of a scope ("See your workspaces"). Known scopes have
/// their own sentence; others fall back to a sentence by level.
nonisolated enum AppScopeStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    static func title(_ scope: String) -> String {
        if let known = known(scope) { return known }
        let kind = AppScopeKind(scope)
        switch kind.family {
        case "net":
            return String(format: t("scope.net", "Connect to %@"), kind.level)
        case "integration":
            let provider = providerName(kind.level.replacingOccurrences(of: ":read", with: ""))
            return kind.level.hasSuffix(":read")
                ? String(format: t("scope.integration.read", "Read your %@ data"), provider)
                : String(format: t("scope.integration.write", "Act on %@ as you"), provider)
        default:
            switch kind.risk {
            case .read: return String(format: t("scope.generic.read", "Read %@"), kind.family)
            case .write, .network: return String(format: t("scope.generic.write", "Change %@"), kind.family)
            case .execute: return String(format: t("scope.generic.execute", "Control %@"), kind.family)
            case .external: return String(format: t("scope.generic.external", "Send through %@"), kind.family)
            }
        }
    }

    /// Display names of integration providers (product names, not localized).
    static func providerName(_ id: String) -> String {
        id == "github" ? "GitHub" : id.prefix(1).uppercased() + id.dropFirst()
    }

    private static func known(_ scope: String) -> String? {
        switch scope {
        case "workspace:read": t("scope.workspace.read", "See your workspaces")
        case "workspace:write": t("scope.workspace.write", "Change your workspaces")
        case "workspace:execute": t("scope.workspace.execute", "Run commands in workspaces")
        case "terminal:read": t("scope.terminal.read", "Read terminal text")
        case "terminal:write": t("scope.terminal.write", "Change terminals")
        case "terminal:execute": t("scope.terminal.execute", "Type into terminals and run commands")
        case "terminal:backend": t("scope.terminal.backend", "Open terminals on other machines for you")
        case "browser:read": t("scope.browser.read", "See browser tabs")
        case "browser:write": t("scope.browser.write", "Change browser tabs")
        case "browser:execute": t("scope.browser.execute", "Control browser pages")
        case "history:read": t("scope.history.read", "Search your browsing history")
        case "agent:read": t("scope.agent.read", "See your agents")
        case "agent:write": t("scope.agent.write", "Report agent status")
        case "notification:read": t("scope.notification.read", "See notifications")
        case "notification:write": t("scope.notification.write", "Post notifications")
        case "machine:read": t("scope.machine.read", "See your machines")
        case "session:read": t("scope.session.read", "See terminal sessions")
        case "session:write": t("scope.session.write", "Change terminal sessions")
        case "actions:run": t("scope.actions.run", "Run cmux actions")
        case "fs:read": t("scope.fs.read", "Read folders you pick")
        case "fs:write": t("scope.fs.write", "Change files in folders you pick")
        case "mcp:expose": t("scope.mcp.expose", "Offer its commands to agents")
        case "clipboard:write": t("scope.clipboard.write", "Copy to the clipboard")
        case "storage:synced": t("scope.storage.synced", "Sync its data across your devices")
        case "coderouter:read": t("scope.coderouter.read", "See CodeRouter status and usage")
        case "coderouter:write": t("scope.coderouter.write", "Change CodeRouter routing")
        case "coderouter:keys": t("scope.coderouter.keys", "Create and revoke CodeRouter keys")
        case "usage:read": t("scope.usage.read", "Read your plan usage and limits")
        default: nil
        }
    }
}
