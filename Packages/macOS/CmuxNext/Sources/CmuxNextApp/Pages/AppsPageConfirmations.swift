import CmuxNextPages
import CmuxNextSettings

/// Which calls of the React App Store page (`cmux.apps.*`, react-pages.md 3.3) pass a native sheet
/// before they reach the owner, and what the sheet says (coordinator Q4: page JS cannot prove a
/// gesture, so the sheet makes the call the user's own). Install, update and Remove always ask;
/// allowing a scope asks, revoking does not. Reads, Hide/Show and Open never ask.
nonisolated enum AppsPageConfirmations {
    /// Whether `op` may need a sheet, so the caller reads the listing (`cmux.apps.catalog.get`) first.
    static func needsDetail(_ op: String) -> Bool {
        ["cmux.apps.install", "cmux.apps.update", "cmux.apps.uninstall", "cmux.apps.grant.set"].contains(op)
    }

    /// The sheet for `op` with `params`, or nil when the call needs none. `detail` is the
    /// listing (`name`, `scopes: [{scope, reason, risk, optional}]`); without it the sheet names
    /// the app id.
    static func confirmation(op: String, params: JSONValue, detail: JSONValue?) -> PageConfirmation? {
        let app = params["app"]?.stringValue ?? ""
        let name = detail?["name"]?.stringValue ?? app
        let scopes = (detail?["scopes"]?.arrayValue ?? []).compactMap(Scope.init)
        switch op {
        case "cmux.apps.install":
            let optional = params["grant_optional"]?.boolValue ?? false
            return PageConfirmation(kind: .install, name: name, scopes: scopes.filter { optional || !$0.optional }.map(\.sheet))
        case "cmux.apps.update":
            return PageConfirmation(kind: .update, name: name, scopes: scopes.filter { !$0.optional }.map(\.sheet))
        case "cmux.apps.uninstall":
            return PageConfirmation(kind: .uninstall, name: name)
        case "cmux.apps.grant.set":
            guard params["granted"]?.boolValue == true, let wanted = params["scope"]?.stringValue else { return nil }
            let row = scopes.first { $0.sheet.scope == wanted }?.sheet
                ?? PageConfirmation.Scope(scope: wanted, reason: "", risk: "standard")
            return PageConfirmation(kind: .grant, name: name, scopes: [row])
        default:
            return nil
        }
    }

    private struct Scope {
        let sheet: PageConfirmation.Scope
        let optional: Bool

        init?(_ value: JSONValue) {
            guard let scope = value["scope"]?.stringValue else { return nil }
            sheet = PageConfirmation.Scope(scope: scope, reason: value["reason"]?.stringValue ?? "",
                                           risk: value["risk"]?.stringValue ?? "standard")
            optional = value["optional"]?.boolValue ?? false
        }
    }
}
