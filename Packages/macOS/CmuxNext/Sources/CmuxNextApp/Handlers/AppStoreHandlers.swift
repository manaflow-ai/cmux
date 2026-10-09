import CmuxNextActions
import CmuxNextApps
import CmuxNextDaemon
import CmuxNextPalette

/// App Store actions (plans/cmux-next/app-platform.md section 3). Opening
/// the window from automation never installs anything; installs are the
/// window's buttons.
enum AppStoreHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        // The App Store is an internal page (a tab of the active window).
        services.pages.register(services.apps)
        registry.bind("appStore.show", run: { invocation in
            let app = invocation["app"]?.stringValue?.trimmingCharacters(in: .whitespaces)
            services.apps.showStore(appID: app?.isEmpty == false ? app : nil, focus: invocation.allowsViewChange)
        })
        registry.bind("appStore.showInstalled", run: { invocation in
            services.apps.showStore(installed: true, focus: invocation.allowsViewChange)
        })
        // Hide and unhide (V9): apps-set hidden on the supervisor with the
        // invocation's origin; the supervisor decides which origins may hide.
        // The app keeps running and answering granted calls.
        func bindHidden(_ id: ActionID, _ hidden: Bool) {
            registry.bind(id, run: { invocation in
                let appID = invocation["app"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
                let apps = services.apps
                if let reason = apps.client.unavailableReason {
                    switch reason {
                    case .needsNewerDaemon: throw ActionFailure.needsDaemonCapability(DaemonAppsTransport.capability)
                    case .notConnected: throw ActionFailure(message: DaemonError.notConnected.description)
                    case .turnedOff(let text): throw ActionFailure(message: text)
                    }
                }
                guard apps.client.app(appID)?.installed == true else {
                    throw ActionFailure(message: RefusalStrings.text("refusal.app.unknown", "No installed app with that id."))
                }
                let origin = AppOrigin(rawValue: invocation.origin.rawValue) ?? .script
                registry.track(Task { @MainActor in
                    do throws(AppsClientError) {
                        try await apps.client.set(appID, .hide(hidden), origin: origin)
                        return nil
                    } catch {
                        return ActionWorkFailure(error.description)
                    }
                })
            })
        }
        // First-party app pages: `app.open` (sidebar label item, palette, CLI
        // `app open <id> [--command <id>]`). Without an app, the palette page lists them.
        registry.bind("app.open", run: { invocation in
            let appID = invocation["app"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !appID.isEmpty else {
                return services.palette.show(page: AppCommandPalette.page(services), relativeTo: context.activeWindow?.window)
            }
            let command = invocation["command"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            do {
                try services.apps.openApp(appID, command: command, focus: invocation.allowsViewChange)
            } catch {
                throw ActionFailure(message: RefusalStrings.text("refusal.app.unknown", "No installed app with that id."))
            }
        })
        // The root palette lists "Open <App>" and the commands of visible apps.
        services.palette.sources.extraProviders.append(AsyncPaletteProvider(id: "apps", showsItemsForEmptyQuery: false) { [weak services] in
            guard let services, !services.registry.disabledFeatures.contains(.apps) else { return [] }
            return AppCommandPalette.rootItems(services)
        })
        services.palette.sources.actionPages["app.command.run"] = { [weak services] in services.map(AppCommandPalette.page) }
        registry.bind("app.command.run", run: { invocation in
            let appID = invocation["app"]?.stringValue ?? ""
            let commandID = invocation["command"]?.stringValue ?? ""
            guard !appID.isEmpty || !commandID.isEmpty else {
                return services.palette.show(page: AppCommandPalette.page(services), relativeTo: context.activeWindow?.window)
            }
            guard let entry = AppCommandPalette.entries(services.apps).first(where: { $0.app.id == appID && $0.matches(commandID) }) else {
                throw ActionFailure(message: RefusalStrings.text("refusal.app.unknown", "No installed app with that id."))
            }
            AppCommandPalette.run(entry, services: services)
        })
        bindHidden("app.hide", true)
        bindHidden("app.unhide", false)
    }
}
