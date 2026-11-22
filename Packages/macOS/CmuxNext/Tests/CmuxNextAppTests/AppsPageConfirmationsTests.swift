@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextSettings
import Testing

/// The React App Store page's native confirmations (react-pages.md 3.3, coordinator Q4): which
/// `cmux.apps.*` calls pass a sheet before they reach the owner, and what the sheet says.
struct AppsPageConfirmationsTests {
    static let caffeinate: JSONValue = [
        "id": "acme.caffeinate", "name": "Caffeinate", "tier": "verified",
        "scopes": [
            ["scope": "power:write", "reason": "Holds a power assertion.", "risk": "standard", "optional": false],
            ["scope": "notifications:write", "reason": "Says when it lets go.", "risk": "sensitive", "optional": true],
        ],
    ]

    @Test func installAsksWithTheNameAndTheRequiredScopes() {
        let sheet = AppsPageConfirmations.confirmation(
            op: "cmux.apps.install", params: ["app": "acme.caffeinate", "grant_optional": false], detail: Self.caffeinate)
        #expect(sheet == PageConfirmation(kind: .install, name: "Caffeinate", scopes: [
            .init(scope: "power:write", reason: "Holds a power assertion.", risk: "standard"),
        ]))
        let all = AppsPageConfirmations.confirmation(
            op: "cmux.apps.install", params: ["app": "acme.caffeinate", "grant_optional": true], detail: Self.caffeinate)
        #expect(all?.scopes.map(\.scope) == ["power:write", "notifications:write"])
    }

    @Test func removeAndUpdateAskWithTheName() {
        let remove = AppsPageConfirmations.confirmation(op: "cmux.apps.uninstall", params: ["app": "acme.caffeinate"], detail: Self.caffeinate)
        #expect(remove == PageConfirmation(kind: .uninstall, name: "Caffeinate"))
        #expect(remove?.isDestructive == true)
        let update = AppsPageConfirmations.confirmation(op: "cmux.apps.update", params: ["app": "acme.caffeinate"], detail: Self.caffeinate)
        #expect(update?.kind == .update)
        #expect(update?.scopes.map(\.scope) == ["power:write"])
    }

    @Test func allowingAScopeAsksRevokingDoesNot() {
        let allow = AppsPageConfirmations.confirmation(
            op: "cmux.apps.grant.set", params: ["app": "acme.caffeinate", "scope": "notifications:write", "granted": true],
            detail: Self.caffeinate)
        #expect(allow == PageConfirmation(kind: .grant, name: "Caffeinate", scopes: [
            .init(scope: "notifications:write", reason: "Says when it lets go.", risk: "sensitive"),
        ]))
        #expect(AppsPageConfirmations.confirmation(
            op: "cmux.apps.grant.set", params: ["app": "acme.caffeinate", "scope": "notifications:write", "granted": false],
            detail: Self.caffeinate) == nil)
    }

    /// Reads, Hide/Show and Open take no sheet; an unknown app falls back to its id.
    @Test func readsAndHidingPassWithoutASheet() {
        for op in ["cmux.apps.catalog.list", "cmux.apps.catalog.get", "cmux.apps.installed.list", "cmux.apps.grants.get",
                   "cmux.apps.open", "cmux.apps.set"] {
            #expect(AppsPageConfirmations.confirmation(op: op, params: ["app": "acme.caffeinate", "hidden": true], detail: Self.caffeinate) == nil)
        }
        #expect(AppsPageConfirmations.needsDetail("cmux.apps.install"))
        #expect(!AppsPageConfirmations.needsDetail("cmux.apps.catalog.list"))
        let unknown = AppsPageConfirmations.confirmation(op: "cmux.apps.uninstall", params: ["app": "x.y"], detail: nil)
        #expect(unknown?.name == "x.y")
    }

    /// The page reaches only its own namespace and the two native ops it uses.
    @Test func thePageAdmitsOnlyItsNamespace() {
        let page = PageDescriptor.apps
        #expect(page.id == "cmux.apps")
        #expect(page.admits("cmux.apps.catalog.list"))
        #expect(page.admits(PageNativeOp.actionRun))
        #expect(!page.admits("cmux.settings.set"))
        #expect(!page.admits("cmux.app.clipboard.write"))
    }
}
