import CmuxNextAccounts
import CmuxNextActions
import CmuxNextAgentIntegrations
import CmuxNextAgentPane
import CmuxNextApps
import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextHomeEngine
import CmuxNextMacScreen
import CmuxNextPages
import CmuxNextServer
import CmuxNextSettings
import CmuxNextTerminal
import CmuxNextUpdater
import Foundation
import UniformTypeIdentifiers
import CmuxNextMobileHost
import CmuxNextWebUpdates

/// Builds the app's React pages with their routes (its own type, not an `AppServices` member:
/// that type's line budget is frozen).
@MainActor
struct PageFactory {
    unowned let services: AppServices

    /// The React History page when Debug Settings `history.surface` is `web`, else nil (the
    /// Swift page). The tunable goes when the React page becomes the default (react-pages.md H3).
    func historyWebPage() -> PageWebView? {
        guard PageTunables.history.value == .web else { return nil }
        let routes = pageRoutes(for: .history)
        guard let page = services.pageHostPool.claim(.history, routes: routes,
                                                      window: services.windows.active?.window, focus: false)
            ?? PageWebView(descriptor: .history, routes: routes) else { return nil }
        PageConnectionWatch(page: page, store: services.machines.local.store).start()
        return page
    }

    /// The App Store page (react-pages.md 3, apps-web-DESIGN.md) on `route` (`#/discover?app=<id>`,
    /// `#/installed`); nil only when the page resources are missing.
    /// `cmux.apps.` goes to the daemon relay behind the native sheet of ``AppsPageConfirmations``
    /// (the sheet reads the listing first so it can name the scopes); `glyph/` is ``AppsGlyphResource``.
    func appsWebPage(route: String?) -> PageWebView? {
        let confirming = appsStoreProvider()
        let native = AppPageNativeProvider(services: services, page: .apps)
        let routes = [PageRoute(prefix: "cmux.apps.", provider: confirming), PageRoute(prefix: "cmux.app.", provider: native)]
        guard let page = PageWebView(descriptor: .apps, routes: routes, route: route, dynamicResources: AppsGlyphResource()) else { return nil }
        confirming.anchor = { [weak page] in page }
        native.anchor = { [weak page] in page }
        PageConnectionWatch(page: page, store: services.machines.local.store).start()
        return page
    }

    /// The App Store's `cmux.apps.*` calls: the daemon relay behind the native consent card of
    /// ``AppsPageConfirmations`` (the card reads the listing first so it can name the scopes). The
    /// App Store page and the `app.install` / `app.remove` actions (CLI, palette, MCP) share it, so
    /// every install shows the same card and only the person's click makes it the user's.
    func appsStoreProvider() -> ConfirmingPageProvider {
        // The organization's DisabledFeatures `apps` turns the store off (the same transport state
        // the native store reads), checked on every call.
        let relay = PolicyGatedPageProvider(inner: DaemonPageRelay(services: services)) { [weak apps = services.apps] in
            apps?.transport.turnedOff
        }
        return ConfirmingPageProvider(inner: relay, presenter: DialogPageConfirmationPresenter()) { op, params in
            guard AppsPageConfirmations().needsDetail(op), let app = params["app"]?.stringValue else { return nil }
            let detail = try? await relay.call("cmux.apps.catalog.get", params: ["app": .string(app)],
                                               context: PageCallContext(page: PageDescriptor.apps.id))
            return AppsPageConfirmations().confirmation(op: op, params: params, detail: detail)
        }
    }

    /// The React CodeRouter page (cmux.coderouter). Its namespace goes to the CodeRouter app's
    /// ops over the control router (``CodeRouterPageProvider``); before the control socket starts
    /// every call answers `unavailable`. `cmux.app.` runs the page's four account actions.
    func coderouterWebPage() -> PageWebView? {
        let ops = CodeRouterAppOps(control: { [weak apps = services.apps] method, params throws(AppHostCapabilityError) in
            guard let router = await MainActor.run(body: { apps?.controlRouter }) else {
                throw AppHostCapabilityError(code: "unavailable", message: "cmux is still starting", retryable: true)
            }
            return try await router.appControl(method, params)
        }, pageShapes: true)
        let registry = services.registry
        let provider = CodeRouterPageProvider(ops: ops, connect: { id in
            registry.perform(ActionID(rawValue: "accounts.connect"), invocation: ActionInvocation(arguments: ["provider": .string(id)], origin: .user))
        })
        let confirming = ConfirmingPageProvider(inner: provider, presenter: DialogPageConfirmationPresenter()) { op, params in
            CodeRouterPageConfirmations.confirmation(op: op, params: params)
        }
        let native = AppPageNativeProvider(services: services, page: .coderouter)
        let routes = [PageRoute(prefix: "cmux.coderouter.", provider: confirming), PageRoute(prefix: "cmux.app.", provider: native)]
        guard let page = PageWebView(descriptor: .coderouter, routes: routes) else { return nil }
        confirming.anchor = { [weak page] in page }
        native.anchor = { [weak page] in page }
        return page
    }

    /// The Cloud app page (cmux.cloud) with the machine list layout from Debug Settings. Its
    /// namespace runs on the Cloud app server through the local daemon (``CloudPageProvider``);
    /// sign-in and sign-out run the app's own account flow after the native sheet.
    func cloudWebPage() -> PageWebView? {
        let native = AppPageNativeProvider(services: services, page: .cloud)
        let cloud = Self.cloudProvider(cloud: services.cloud, registry: services.machines)
        native.forward = { op, params, context in try await cloud.call(op, params: params, context: context) }
        let routes = [PageRoute(prefix: "cmux.cloud.", provider: cloud), PageRoute(prefix: "cmux.app.", provider: native)]
        let attributes = ["cloud-machines-layout": PageTunables.cloudMachinesLayout.value.rawValue]
        let page = services.pageHostPool.claim(.cloud, routes: routes,
                                               documentAttributes: attributes,
                                               window: services.windows.active?.window, focus: false)
            ?? PageWebView(descriptor: .cloud, routes: routes, documentAttributes: attributes)
        native.anchor = { [weak page] in page }
        if let page { PageConnectionWatch(page: page, store: services.machines.local.store).start() }
        return page
    }

    /// The Cloud page's provider for `cloud`'s link. The Cloud app server reaches its backend only
    /// through the credential relay, which the classic link never registers (cx-t2rz P3-1): there
    /// the page reads Cloud's own `/api/vm` list (``CloudClassicPageOps``), as the CLI and the
    /// sidebar do, instead of answering "not available until cmux reconnects" for good.
    static func cloudProvider(cloud account: CloudService, registry: MachineRegistry) -> CloudPageProvider {
        let classic = account.configuration.linkSource == .legacy
            ? CloudClassicPageOps(backend: .app(cloud: account, registry: registry)) : nil
        return CloudPageProvider(op: classic.map(CloudAppLinks.ops(classic:)) ?? account.appOps,
                                 signIn: { [weak account] in await account?.auth.signIn() ?? false },
                                 signOut: { [weak account] in await account?.signOut() },
                                 feed: classic.map(CloudAppLinks.feed(classic:)),
                                 account: { [weak account] in
                                     CloudPageProvider.accountValue(signedIn: account?.isSignedIn ?? false, user: account?.auth.user?.id,
                                                                    team: account?.auth.teamID)
                                 })
    }

    /// The Settings page's engine options.
    static let settingsEngineOptions = PageEngineOptions.standard

    /// The React Settings page (R82) on `route` (`#/settings/<section>?focus=<key>`). Its namespace
    /// goes to `SettingsPageProvider` (interim owner; the daemon relay once the config actor
    /// serves `settings.*`), `cmux.app.` to the native ops.
    func settingsPage(route: String?) -> PageWebView? {
        guard let settings = services.settings else { return nil }
        let provider = SettingsPageProvider(settings: settings, domains: { [weak services] in
            ["themes": services?.themes.catalog.names ?? [], "font_families": SettingsPageDomains.fontFamilies, "sounds": SettingsPageDomains.sounds, "recent_fonts": services?.settings?.recentFonts.families ?? []]
        }, hostLists: { [weak services] in services?.settingsWindow.pageHostLists() ?? .null }, wideningGate: services.wideningGate)
        provider.removeDevice = { [weak services] id in await services?.devices.remove(id: id) }
        provider.setDeviceFullAccess = { [weak services] id, on in await services?.devices.setFullAccess(id: id, on: on) }
        provider.setJoinConsent = { [weak services] surface, on in
            guard let services, let surface = JoinConsentSurface(rawValue: surface) else { return nil }
            return await services.joinConsent.set(surface, on: on)
        }
        provider.personBacksGesture = { [weak services] uptime in services?.personInput.backs(uptime) ?? false }
        // Touch ID or the password, which every turn-on of Full access or Dedicated agent machine needs.
        provider.ownerConfirm = LocalDeviceOwnerAuthenticator()
        provider.setMachineVmHost = { [weak services] id, on in
            guard let services else { return nil }
            return await services.cloudVmHost.set(id, on: on, reachable: services.settingsWindow.vmHostReach(id) == true)
        }
        let accounts = services.accounts.model
        provider.accountsState = { (try? JSONValue.parse(JSONEncoder().encode(accounts.pageState))) ?? .null }
        provider.accountsRun = { params in
            guard let action = AccountsPageAction(field: { params[$0]?.stringValue }) else {
                throw PageError.invalidParams("unknown accounts action")
            }
            if let error = await accounts.perform(action) { return ["error": .string(error)] }
            return .object([:])
        }
        provider.agents = services.agentHarnesses
        let harnesses = SettingsHarnesses(
            environment: { [weak services] in services.flatMap(QuitAgents.environment) },
            openTerminal: { [weak services] line in _ = services?.inFrontPane { $0.newTerminalTab(typing: line + "\r") } },
            runUpdate: { [weak services] params, context in
                guard let services, let updates = services.agentHarnesses.updates else { throw PageError.closed }
                return try await updates.runPage(params, context: context, registry: services.registry)
            },
            updateState: { [weak services] in services?.agentHarnesses.updates?.state ?? .array([]) },
            refreshUpdates: { [weak services] in await services?.agentHarnesses.updates?.refresh() }
        )
        provider.harnessesState = { harnesses.state }
        provider.harnessesRun = { params, context in try await harnesses.run(params, context: context) }
        let cloud = services.cloud
        let environments = CloudEnvironmentsSettings(
            available: { [weak cloud] in cloud.map { $0.configuration.linkSource == .appServer && $0.auth.isSignedIn } ?? false },
            list: { [weak cloud] in
                guard let cloud else { throw PageError.closed }
                return try JSONEncoder().encode(await cloud.appOps("cloud.environment.list", .object([:]), nil, .script))
            },
            save: { [weak cloud] args in
                guard let cloud else { throw PageError.closed }
                _ = try await cloud.appOps("cloud.environment.set", try JSONDecoder().decode(CmuxNextDaemon.JSONValue.self, from: args), UUID().uuidString, .user)
            },
            approvedCall: { [weak cloud] op, id, confirm in
                guard let cloud else { throw PageError.closed }
                do { _ = try await cloud.appServerApprovedCall(op, args: .object(["environment": .string(id)]), confirm: confirm) }
                catch CloudMachineCreateFlow.Failure.declined { return false }
                return true
            },
            confirm: { [weak services] title, body, button in
                await withCheckedContinuation { continuation in
                    CloudPresenter.confirm(title, body, button: button, identifier: CloudPresenter.environmentConfirmIdentifier,
                                           in: services?.windows.active?.window) { continuation.resume(returning: $0) }
                }
            })
        provider.environmentsState = { (try? JSONValue.parse(JSONEncoder().encode(environments.state))) ?? .null }
        provider.environmentsRun = { params in
            guard let run = try? JSONDecoder().decode(CloudEnvironmentsRun.self, from: JSONSerialization.data(withJSONObject: params.foundationObject)) else {
                throw PageError.invalidParams("unknown environments action")
            }
            return (try? JSONValue.parse(JSONEncoder().encode(await environments.run(run)))) ?? .object([:])
        }
        let devices = services.deviceHub.settingsModel
        provider.devicesState = { (try? JSONValue.parse(JSONEncoder().encode(devices.state))) ?? .null }
        provider.devicesRun = { params in
            let run: MacScreenDevicesSettings.Run
            do {
                run = try JSONDecoder().decode(MacScreenDevicesSettings.Run.self,
                                               from: JSONSerialization.data(withJSONObject: params.foundationObject))
            } catch {
                throw PageError.invalidParams("unknown devices action")
            }
            let result = await devices.run(run)
            return (try? JSONValue.parse(JSONEncoder().encode(result))) ?? .object([:])
        }
        provider.devicesWatching = { on in if on { devices.beginWatching() } else { devices.endWatching() } }
        provider.integrations = SettingsAgentIntegrations(cli: { [bundled = services.bundledCLI] in await bundled.resolve() })
        provider.setTheme = { [weak services] level, spec in try services?.settingsWindow.setPageTheme(level: level, spec: spec) }
        provider.acceptsTheme = { [weak services] text in services?.settingsWindow.acceptsTheme(text) ?? false }
        provider.themeColors = { [weak services] in (services?.themes.catalog).map { c in c.names.compactMap { c.colors[$0] } } ?? [] }
        let registry = services.registry
        provider.sectionActions = { section in
            .array(SettingsSchema.actions(in: section).compactMap { id in
                // An action a setting turns off (Import from Browser with `browser.import.enabled` off) leaves the page.
                guard let descriptor = registry.descriptor(for: id), registry.settingOffReason(id) == nil else { return nil }
                return ["id": .string(id.rawValue), "title": .string(descriptor.title),
                        "enabled": .bool(registry.isAvailable(id))]
            })
        }
        provider.pickFolders = { [weak services] in
            guard let urls = await services?.viewers.picker.open(.init(choose: .folders, allowsMultiple: true)) else { return nil }
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
            return urls.map { url in
                let path = url.standardizedFileURL.path
                // Inside home: `~/…` (the schema accepts absolute or `~/` paths); home itself stays absolute.
                return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
            }
        }
        provider.themeOverrides = { GhosttyRuntime.shared.configDiagnosticsSnapshot?.colorOverrides ?? [] }
        provider.openThemeOverride = { [weak services] override in
            guard let services else { return false }
            return services.linkOpener.openFile(URL(fileURLWithPath: override.file), from: services.windows.active?.focusedPane,
                                                asText: true, at: FilePosition(line: override.line))
        }
        provider.themeFiles = SettingsThemeFiles(
            folders: {
                .init(resources: GhosttyRuntime.resourcesDirectory(), home: FileManager.default.homeDirectoryForCurrentUser,
                      environment: ProcessInfo.processInfo.environment)
            },
            reload: { [weak services] in await services?.themes.catalog.reload() },
            pickFile: { [weak services] in await services?.viewers.picker.open(.init(choose: .files))?.first })
        provider.backdropImages = SettingsWindowService.userImages.map { images in
            SettingsBackdropImages(images: images) { [weak services] in
                await services?.viewers.picker.open(.init(choose: .files, types: [.image, .movie]))?.first
            }
        }
        let museumArt = MuseumArtSession()
        provider.museumArt = museumArt
        provider.workspaceBackgrounds = SettingsWorkspaceBackgrounds(
            title: { [weak services] id in services?.workspace(id: id)?.displayName },
            value: { [weak services] id in services?.themes.workspaceBackground(id) },
            set: { [weak services] value, id in services?.themes.setWorkspaceBackground(value, for: id) },
            preview: { [weak services] value, id in services?.themes.previewWorkspaceBackground(value, for: id) },
            opacity: SettingsWorkspaceOpacity(
                value: { [weak services] id in services?.themes.workspaceOpacity(id) },
                set: { [weak services] value, id in services?.themes.setWorkspaceOpacity(value, for: id) },
                preview: { [weak services] value, id in services?.themes.previewWorkspaceOpacity(value, for: id) }))
        let native = AppPageNativeProvider(services: services, page: .settings)
        // Your own backgrounds from a link, removed or revealed (BackdropImagesPageProvider).
        let images = provider.backdropImages.map { images in
            BackdropImagesPageProvider(images: images.images, use: { [weak provider] in try await provider?.useBackdropImage($0) ?? "" },
                                       inUse: { [weak services] in services?.settings?.snapshot.backdropSelection }, settings: services.settings,
                                       pickFolder: { [weak services] in await services?.viewers.picker.open(.init(choose: .folders))?.first })
        }
        let routes = [PageRoute(prefix: "cmux.settings.", provider: provider), PageRoute(prefix: "cmux.app.", provider: native),
                      // Agents > Chiefs: the same Chief editor routes as Home (ChiefProfilePageRelay, AgentHarnessCenter).
                      PageRoute(prefix: ChiefProfilePageRoute.prefix, provider: ChiefProfilePageRoute(owner: services.home.chief)),
                      PageRoute(prefix: ChiefBackendPageRoute.prefix, provider: ChiefBackendPageRoute(center: services.agentHarnesses)),
                      PageRoute(prefix: "cmux.settings.mobile.", provider: MobilePageProvider(host: services.iphone)),
                      PageRoute(prefix: ChannelsPageProvider.prefix,
                                provider: ChannelsPageProvider(updater: services.updater, daemon: { @MainActor [weak services, daemons = services.acpmuxDaemons] in
                                    // The acpmux this app starts; none in a showcase or with the mock agent host.
                                    guard let environment = services.flatMap(QuitAgents.environment) else { return nil }
                                    return (AcpmuxDaemonSummary.title, await AcpmuxDaemonSummary.current(environment, daemons: daemons).text)
                                }, machines: { [updates = services.daemonUpdates] in PageFactory.otherMachines(updates.board) },
                                // The person's Update on a machine of that row: the app's policy asks it again.
                                updateMachine: { [updates = services.daemonUpdates] id in
                                    await updates.board.update(id) { await updates.policy.retry($0) }
                                        ? nil : DaemonUpdateBoard.updateRefused
                                })),
                      PageRoute(prefix: WebUpdatesPageProvider.prefix, provider: WebUpdatesPageProvider()),
                      // Chief > Voice input: the home.voiceInput tunable (DEV and NIGHTLY).
                      PageRoute(prefix: ChiefVoiceInputPageRoute.prefix, provider: ChiefVoiceInputPageRoute()),
                      // Settings > Menus: right-click menu arrangements (cmux.json contextMenus).
                      PageRoute(prefix: ContextMenusPageProvider.prefix, provider: services.settingsWindow.contextMenusRoute),
                      // Settings > Server: Restart… (the toast's confirm) and Pair (the Server panel).
                      PageRoute(prefix: ServerSettingsPageRoute.prefix, provider: ServerSettingsPageRoute(
                          confirmRestart: { [weak services] in services?.serverUpdates.confirmRestart(kind: $0, host: $1) },
                          pair: { [weak services] in services?.registry.perform("server.showPanel") }))]
            + (images.map { [PageRoute(prefix: BackdropImagesPageProvider.prefix, provider: $0)] } ?? [])
        // `appearance.surfaces.settings` colors the page, as it colored the Swift Settings view.
        let catalog = services.settingsWindow.backdropCatalog
        let dynamicResources = SettingsBackdropThumbnails(choices: catalog.catalog.choices,
                                                          currentChoices: { catalog.catalog.choices },
                                                          userImages: SettingsWindowService.userImages, museum: museumArt,
                                                          iconPNG: { [weak services] icon in
                                                              await SettingsIconAssets.png(icon, owner: services?.machines.local)
                                                          })
        let page = services.pageHostPool.claim(.settings, routes: routes, route: route, options: Self.settingsEngineOptions,
                                               surface: .settings,
                                               dynamicResources: dynamicResources,
                                               window: services.windows.active?.window, focus: false)
            ?? PageWebView(descriptor: .settings, routes: routes, route: route, options: Self.settingsEngineOptions,
                           surface: .settings, dynamicResources: dynamicResources)
        native.anchor = { [weak page] in page }
        // An image or movie dropped on Settings becomes the background (cx-t2x.8).
        page?.fileDrop = PageFileDrop(accepts: { url in BackdropUserImages.isImage(url) }) { [weak provider] url in
            // task-owner: one short copy and settings write per drop; a failed one changes nothing
            Task { try? await provider?.useBackdropImage(url) }
        }
        return page
    }

    /// The routes of `page`: its namespaces to the daemon relay, `cmux.app.` to the native ops
    /// (whose confirmed ops run on the namespace relay after the sheet).
    func pageRoutes(for page: PageDescriptor) -> [PageRoute] {
        let relay = DaemonPageRelay(services: services)
        let native = AppPageNativeProvider(services: services, page: page)
        native.forward = { op, params, context in try await relay.call(op, params: params, context: context) }
        return page.namespaces.map { PageRoute(prefix: $0, provider: relay) } + [PageRoute(prefix: "cmux.app.", provider: native)]
    }

    /// Settings > Updates' row of other machines from the daemon update board: a machine that
    /// cannot update in place gets the Update button.
    static func otherMachines(_ board: DaemonUpdateBoard) -> ChannelsPageProvider.Machines? {
        guard let row = board.otherMachines else { return nil }
        return ChannelsPageProvider.Machines(title: row.title, lines: row.lines, updates: row.machines.map { $0.canUpdate ? $0.id : nil },
                                             updateLabel: DaemonUpdateBoard.updateLabel)
    }
}
