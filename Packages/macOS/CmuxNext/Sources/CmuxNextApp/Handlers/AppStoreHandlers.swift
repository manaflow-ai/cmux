import CmuxNextActions
import CmuxNextApps
import CmuxNextDaemon
import CmuxNextPages
import CmuxNextPalette
import CmuxNextSettings

/// App Store actions (plans/cmux-next/app-platform.md section 3). Opening
/// the window from automation never installs anything; installs and removals
/// pass the App Store's native consent card (`app.install`, `app.remove`).
enum AppStoreHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let previewTitle = SettingsSchema.descriptor(for: CmuxConfigSnapshot.previewFeaturesPath)?.title
            ?? CmuxConfigSnapshot.previewFeaturesPath.joined(separator: ".")
        let services = context.services
        let preview: @MainActor () -> String? = { [weak services] in
            services?.settings?.snapshot.previewFeatures == true ? nil : previewTitle
        }
        // The App Store is an internal page (a tab of the active window).
        services.pages.register(services.apps)
        // `category` (cmux's features) is still accepted and ignored: those are Settings now.
        registry.bind("appStore.show", unavailable: preview, invoke: { invocation in
            let app = invocation["app"]?.stringValue?.trimmingCharacters(in: .whitespaces)
            services.apps.showStore(appID: app?.isEmpty == false ? app : nil, tab: invocation["tab"]?.stringValue.flatMap(AppStoreTab.init(argument:)), focus: invocation.allowsViewChange)
        })
        registry.bind("appStore.showInstalled", unavailable: preview, invoke: { invocation in
            services.apps.showStore(tab: .installed, focus: invocation.allowsViewChange)
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
        // Install and remove (CLI `cmux apps install|remove [--deploy <target>]`, palette, MCP): the
        // App Store's consent card (AppsStoreChange); only the person's click makes it the user's.
        for (id, kind) in [("app.install", AppsStoreChange.Kind.install), ("app.remove", .remove)] as [(ActionID, AppsStoreChange.Kind)] {
            registry.bindEffect(id, requires: nil, effect: { invocation in
                if let reason = services.apps.client.unavailableReason { throw Self.unavailable(reason) }
                let change = AppsStoreChange(kind: kind, app: invocation["app"]?.stringValue ?? "", deploy: invocation["deploy"]?.stringValue)
                guard !change.app.isEmpty else {
                    services.apps.showStore(tab: kind == .install ? .discover : .installed, focus: invocation.allowsViewChange)
                    return .done
                }
                let provider = PageFactory(services: services).appsStoreProvider()
                provider.anchor = { [weak services] in services?.windows.active?.window?.contentView }
                // action-wait-allow: the consent card shows at once; the change exists only after the person confirms
                return .waiting(.daemonEcho) { Self.failure(await change.send(through: provider)) }
            })
        }
    }

    /// The refusal of a store change that did not commit, nil when it did.
    static func failure(_ outcome: AppsStoreChange.Outcome) -> ActionWorkFailure? {
        switch outcome {
        case .done: nil
        case .declined: ActionWorkFailure(RefusalStrings.text("refusal.app.declined", "Nothing changed: the request was declined on the confirmation card."))
        case .unknownApp: ActionWorkFailure(RefusalStrings.text("refusal.app.notListed", "No app with that id in the App Store."))
        case .refused(let code, let message): ActionWorkFailure("\(code): \(message)")
        }
    }

    /// Why an app action cannot run while the supervisor is unreachable.
    static func unavailable(_ reason: AppsUnavailableReason) -> ActionFailure {
        switch reason {
        case .needsNewerDaemon: ActionFailure.needsDaemonCapability(DaemonAppsTransport.capability)
        case .notConnected, .notReady, .turnedOff: ActionFailure(message: reason.text)
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
        case .notDeployed: ActionFailure(message: RefusalStrings.text("refusal.app.notDeployed", "This app is not running yet. Install it with a deploy target, for example: cmux apps install <app> --deploy self-hosted:<host>."))
        }
    }
}
