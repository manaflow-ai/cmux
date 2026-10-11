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
                if let reason = apps.client.unavailableReason { throw Self.unavailable(reason) }
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
            let work: ActionWork?
            do throws(AppsServiceError) {
                work = try services.apps.openApp(appID, command: command, focus: invocation.allowsViewChange, origin: invocation.origin)
            } catch {
                throw Self.failure(error)
            }
            if let work { registry.track(work) }
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
            if let reason = services.apps.client.unavailableReason { throw Self.unavailable(reason) }
            let entries = AppCommandPalette.entries(services.apps, origin: invocation.origin)
            guard let entry = entries.first(where: { $0.app.id == appID && $0.matches(commandID) }) else {
                throw ActionFailure(message: RefusalStrings.text("refusal.app.unknown", "No installed app with that id."))
            }
            registry.track(AppCommandPalette.run(entry, services: services, origin: invocation.origin))
        })
        bindHidden("app.hide", true)
        bindHidden("app.unhide", false)
    }

    /// Why an app action cannot run while the supervisor is unreachable.
    static func unavailable(_ reason: AppsUnavailableReason) -> ActionFailure {
        switch reason {
        case .needsNewerDaemon: ActionFailure.needsDaemonCapability(DaemonAppsTransport.capability)
        case .notConnected: ActionFailure(message: DaemonError.notConnected.description)
        case .turnedOff(let text): ActionFailure(message: text)
        }
    }

    /// `app.open`'s refusal: the unavailable reason, else why this app did not open.
    static func failure(_ error: AppsServiceError) -> ActionFailure {
        switch error {
        case .unavailable(let reason): unavailable(reason)
        case .unknownApp: ActionFailure(message: RefusalStrings.text("refusal.app.unknown", "No installed app with that id."))
        case .disabled: ActionFailure(message: RefusalStrings.text("refusal.app.disabled", "This app is turned off. Turn it on in the App Store."))
        case .noPage: ActionFailure(message: RefusalStrings.text("refusal.app.noPage", "This app has no page to open."))
        case .noWindow: ActionFailure(message: RefusalStrings.text("refusal.app.noWindow", "Open a cmux window first, then open the app."))
        case .unknownCommand: ActionFailure(message: RefusalStrings.text("refusal.app.unknownCommand", "This app has no command with that id."))
        }
    }
}
