import CmuxNextActions

/// App Store actions (plans/cmux-next/app-platform.md section 3). Opening
/// the window from automation never installs anything; installs are the
/// window's buttons.
enum AppStoreHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        registry.bind("appStore.show", run: { invocation in
            let app = invocation["app"]?.stringValue?.trimmingCharacters(in: .whitespaces)
            services.apps.showStore(appID: app?.isEmpty == false ? app : nil)
        })
        registry.bind("appStore.showInstalled", run: { _ in services.apps.showStore(installed: true) })
        // Hide and unhide (V9): view preference only; the app keeps running and answering granted calls.
        func bindHidden(_ id: ActionID, _ hidden: Bool) {
            registry.bind(id, run: { invocation in
                let appID = invocation["app"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
                guard services.apps.registry.app(appID)?.isInstalled == true else {
                    throw ActionFailure(message: RefusalStrings.text("refusal.app.unknown", "No installed app with that id."))
                }
                registry.track(Task { @MainActor in
                    do {
                        try await services.apps.registry.setHidden(appID, hidden)
                        return nil
                    } catch {
                        return ActionWorkFailure(String(describing: error))
                    }
                })
            })
        }
        bindHidden("app.hide", true)
        bindHidden("app.unhide", false)
    }
}
