import CmuxNextActions
import CmuxNextApps
import CmuxNextDaemon

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
        // Hide and unhide (V9): apps-set hidden on the supervisor with the
        // invocation's origin; any origin may hide (it grants nothing). The
        // app keeps running and answering granted calls.
        func bindHidden(_ id: ActionID, _ hidden: Bool) {
            registry.bind(id, run: { invocation in
                let appID = invocation["app"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
                let apps = services.apps
                if let reason = apps.client.unavailableReason {
                    throw ActionFailure(message: reason == .needsNewerDaemon
                        ? RefusalStrings.needsDaemonCapability(DaemonAppsTransport.capability) : DaemonError.notConnected.description)
                }
                guard apps.client.app(appID)?.installed == true else {
                    throw ActionFailure(message: RefusalStrings.text("refusal.app.unknown", "No installed app with that id."))
                }
                let origin = AppOrigin(rawValue: invocation.origin.rawValue) ?? .cli
                registry.track(Task { @MainActor in
                    do throws(AppsClientError) {
                        try await apps.setHidden(appID, hidden, origin: origin)
                        return nil
                    } catch {
                        return ActionWorkFailure(error.description)
                    }
                })
            })
        }
        bindHidden("app.hide", true)
        bindHidden("app.unhide", false)
    }
}
