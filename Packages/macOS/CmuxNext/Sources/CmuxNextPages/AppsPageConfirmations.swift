public import CmuxNextSettings
import Foundation

/// Which calls of the React App Store page (`cmux.apps.*`, react-pages.md 3.3) pass a native sheet
/// before they reach the owner, and what the sheet says (coordinator Q4: page JS cannot prove a
/// gesture, so the sheet makes the call the user's own). Install, update, Remove, `set` (turn on or
/// off, the sandbox) and allowing a scope ask. Reads, Hide/Show (`cmux.apps.hidden.set`) and
/// revoking a scope (`cmux.apps.grant.revoke`) need only the person's gesture (page-router.json
/// `gesture`); Open is the host action `app.open`. In CmuxNextPages (not the app target) so every
/// host shares one sheet table.
public nonisolated struct AppsPageConfirmations {
    public init() {}

    /// Whether `op` may need a sheet, so the caller reads the listing (`cmux.apps.catalog.get`) first.
    public func needsDetail(_ op: String) -> Bool {
        ["cmux.apps.install", "cmux.apps.update", "cmux.apps.uninstall", "cmux.apps.grant.set", "cmux.apps.set"].contains(op)
    }

    /// The sheet for `op` with `params`, or nil when the call needs none. `detail` is the
    /// listing (`name`, `scopes: [{scope, reason, risk, optional}]`); without it the sheet names
    /// the app id.
    public func confirmation(op: String, params: JSONValue, detail: JSONValue?) -> PageConfirmation? {
        let app = params["app"]?.stringValue ?? ""
        let name = detail?["name"]?.stringValue ?? app
        let scopes = (detail?["scopes"]?.arrayValue ?? []).compactMap(Scope.init)
        switch op {
        case "cmux.apps.install":
            let optional = params["grant_optional"]?.boolValue ?? false
            return PageConfirmation(kind: .install, name: name, scopes: scopes.filter { optional || !$0.optional }.map(\.sheet),
                                    deployTarget: params["deploy"]?["target"]?.stringValue)
        case "cmux.apps.update":
            return PageConfirmation(kind: .update, name: name, scopes: scopes.filter { !$0.optional }.map(\.sheet))
        case "cmux.apps.uninstall":
            return PageConfirmation(kind: .uninstall, name: name)
        case "cmux.apps.set":
            // The daemon takes `set` only with this sheet's confirmation (page-router.json `confirm`).
            // The sheet names one change, so a call that changes more than one field gets no sheet
            // (the daemon then refuses it): an approval never covers a change the sheet did not name.
            let fields = ["enabled", "sandboxed", "hidden"].filter { params[$0] != nil }
            guard fields.count == 1 else { return nil }
            let title = if let sandboxed = params["sandboxed"]?.boolValue {
                sandboxed ? String(format: PageStrings.sandboxOn, name) : String(format: PageStrings.sandboxOff, name)
            } else if let enabled = params["enabled"]?.boolValue {
                String(format: enabled ? PageStrings.enable : PageStrings.disable, name)
            } else {
                String(format: PageStrings.change, name)
            }
            return PageConfirmation(kind: .custom, name: title)
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
