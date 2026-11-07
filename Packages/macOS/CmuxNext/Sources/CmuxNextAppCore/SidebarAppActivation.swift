public import CmuxNextActions

extension ActionRegistry {
    /// What a sidebar app item's click runs (R63/R64): `cmux.apps.open {app}` (it
    /// opens the app's screen or page as the manifest says) once it is
    /// registered. INTERIM until then: Home and the App Store keep their
    /// show actions, every other app opens its page (`app.open`).
    @MainActor public func sidebarAppActivation(_ app: String) -> (ActionID, [String: ActionValue]) {
        let registered = { (id: ActionID) in self.action(for: id) != nil }
        if registered("cmux.apps.open") { return ("cmux.apps.open", ["app": .string(app)]) }
        if let action = Self.interimSidebarAppActions[app], registered(action) { return (action, [:]) }
        return ("app.open", ["app": .string(app)])
    }

    private static let interimSidebarAppActions: [String: ActionID] = ["cmux/home": "home.show", "cmux/app-store": "appStore.show"]
}
