import AppKit
import CmuxNextBrowser
import CmuxNextControl
import CmuxNextDesign
import CmuxNextSettings
import os

// Launch calls for the tagged control socket (`action.list/describe/run`) over the registry (task 014,
// see Startup+Core.swift).
extension AppDelegate {
    /// After the first frames: the settings migrations, then the control socket and its method groups,
    /// then Share This Mac.
    func registerControl(services: AppServices, settings: SettingsController) {
        let registry = services.registry
        Task {
            await settings.waitForLoad(atLeast: 1); await launchSettle.settled(within: .seconds(4)) // control socket: after the first frames (cx-z9kz0)
            // `app.quitBehavior: "end"` (first release) is now "end-keep-layout".
            _ = try? await settings.migrateLegacyQuitBehavior()
            _ = try? await settings.migrateLegacyWorkspaceRowKeys() // `sidebar.showWorkspaceDirectory` / `showCounts` move to `sidebar.workspaceRow.*`
            _ = try? await settings.migrateLegacyPaneToolbarButtons() // `tabs.hiddenButtons` becomes `tabs.toolbarButtons`
            // Classic cmux keys next reads under another name (`ClassicSettingRename`).
            _ = try? await settings.migrateClassicSettings()
            // Shortcuts and settings classic cmux's Settings kept in its preferences (`ClassicShortcutImport`, `ClassicPreferenceImport`).
            _ = try? await settings.importClassicShortcuts(marker: .standard)
            _ = try? await settings.importClassicPreferences(marker: .standard)
            do {
                try control.start(registry: registry, settings: settings, launch: environment.launch, services: services)
                control.registerCloudMethods(services)
                control.registerAccountsMethods(services)
                control.registerBillingMethods(services)
                control.registerRemoteMethods(services)
                control.registerMobileMethods(services)
                control.registerUpdateMethods(services.updater, services: services)
                control.registerInputMethods(services)
                control.registerSettingsDebugMethods(services)
                control.registerPageDebugMethods(services)
                control.registerRemoteBrowserDebugMethods(services)
                RemoteViewDebugMethods(services: services).register(on: control.service?.router)
                services.registerMacScreenDebug(on: control.service?.router)
                services.registerDeviceHubDebug(on: control.service?.router)
                DebugNowPlaying.register(on: control.service?.router, services: services)
                DebugDownloads.register(on: control.service?.router, services: services)
                DebugCEFDevToolsLayout.register(on: control.service?.router, services: services)
                #if DEBUG
                // The Chromium host app prototype (browserHost.helperPrototype; cef-helper-app-DESIGN.md).
                // Socket focus policy: `open` makes the page first responder only with focus: true.
                let chromiumHost = ChromiumHostPrototype(makeConfiguration: { ChromiumHostPrototype.bundledConfiguration() },
                                                         tunables: TunableStore.shared)
                control.service?.router.register([
                    .mainActor("debug.chromium_host") { [weak services] call in
                        let controller = services?.windows.controllers.first
                        let pane = (call.params["pane"]?.stringValue ?? controller?.focus.state.pane).flatMap { controller?.content?.paneController(key: $0) }
                        let fields = chromiumHost.handle(op: call.params["op"]?.stringValue, url: call.params["url"]?.stringValue,
                                                         over: pane?.view.contentHost, focus: call.params["focus"]?.boolValue == true)
                        return .value(JSONValue(foundation: fields) ?? .null)
                    },
                    .async("debug.chromium_host.measure") { call in
                        guard let fields = await chromiumHost.measure(op: call.params["op"]?.stringValue, count: call.params["count"]?.intValue)
                        else { return ["error": "no running Chromium host"] }
                        return .object(fields.mapValues(JSONValue.number))
                    }.withDeadline(.fixed(.seconds(60))),
                ])
                #endif
                DebugBrowserExternal.register(on: control.service?.router, services: services)
                DebugCloudMove.register(on: control.service?.router, services: services)
                DebugTerminalLinks.register(on: control.service?.router, services: services)
                if let router = control.service?.router {
                    // The passkey hand-off: an agent's request waits for the person's banner click.
                    let passkeys = BrowserPasskeyRequests(host: AppBrowserPasskeyHost(services: services))
                    services.notifications.onPasskeyBanner = { id in Task { _ = try? await passkeys.answer(id) } }
                    BrowserPageService(engine: AppBrowserPageEngine(services: services), passkeys: passkeys,
                                       agentMouse: { [weak settings] in
                                           await MainActor.run { settings?.snapshot.browserAgentMouse } ?? AgentMouseSetting().fallback
                                       }).install(on: router)
                    services.apps.attach(router: router)
                }
                logger.info("control socket \(self.control.socketPath ?? "", privacy: .public)")
            } catch {
                logger.error("control socket failed: \(String(describing: error), privacy: .public)")
            }
            // Share This Mac resumes when the person left it on.
            services.macScreenPages.activate()
        }
    }
}
