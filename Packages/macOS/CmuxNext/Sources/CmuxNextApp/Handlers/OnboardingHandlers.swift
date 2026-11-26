import AppKit
import CmuxNextActions
import CmuxNextAgentActivity
import CmuxNextBrowser
import CmuxNextCookieImport
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextImportCards
import CmuxNextImportSuggestions
import CmuxNextOnboarding

/// Import and default-app actions. Import from Browser and Make cmux Yours (on the current settings; Skip restores them) open
/// the tool window (`OnboardingService`); Make cmux the Default Terminal asks macOS directly
/// for each handler; Make cmux the Default Browser asks macOS directly
/// (macOS shows its confirmation); Import Workspaces from Classic cmux opens
/// classic's last saved session.
enum OnboardingHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services; registry.bindEffect("home.showSetup") { invocation in services.onboarding.setup.reopen(); _ = registry.perform("home.show", invocation: invocation); _ = registry.perform("home.openChief", invocation: invocation); return .done }
        registry.bind("importFromBrowser", run: { _ in services.onboarding.show(step: .importData) }); registry.bindEffect("home.makeItYours") { _ in services.onboarding.show(step: .makeItYours); return .done }
        BrowserImportGate(host: services).install(into: registry) { BrowserImportOfferStrings.turnedOff }
        registry.bind("browserProfile.removeImportedData", run: { invocation in
            let record = try context.browserProfile(invocation), sync = services.onboarding.historySync
            Task {  // task-owner: one removal the person asked for; the toast reports it, or that it failed
                let counts = try? await sync.removeImported(profile: record.id, bookmarks: services.importedBookmarkSink)
                BrowserFileImport.toast(services, id: "browser-import-removed", counts.removalText(profile: record.name))
            }
        })
        // No path argument: only the person's own pick in the open panel brings passwords in.
        registry.bind("password.importCSV", run: { invocation in
            try PasswordCSVFiles(services: services).chooseImport(profile: BookmarkResolver(services: services).profile(invocation))
        })
        registry.bind("browser.importFromFiles", run: { invocation in
            BrowserFileImport(services: services).run(profile: BookmarkResolver(services: services).profile(invocation))
        })
        // Cookies of one browser profile, for the CLI and agents: an agent's run asks the person, whose own click alone allows.
        let cef = services.cache.cef
        let cookieImports = CookieImportService(host: CookieImportHost(
            requester: { invocation in
                let agentTabs = services.agentTabs
                let tabs = services.daemon.store.workspaces.flatMap { workspace in
                    workspace.screens.flatMap(\.panes).flatMap(\.tabs).map { tab in
                        CookieImportCandidate(tabID: tab.id, title: tab.displayTitle, workspace: workspace.displayName,
                                              agentSession: agentTabs.sessions[agentTabs.tabKey(tab.id, machine: services.daemon.machineID)] ?? tab.agentSession?.session,
                                              terminalIDs: [tab.terminalID?.rawValue, tab.terminalResourceID?.rawValue].compactMap(\.self),
                                              isHomeChat: tab.isHomeDockPage && workspace.kind == "home")
                    }
                }
                // The caller's acpmux session, by id (O(1)): its title and latest reply.
                return CookieImportRequester(invocation, among: tabs) { services.agentLanes.lane($0).map { ($0.title, $0.preview) } }
            },
            target: { invocation in
                let id = BookmarkResolver(services: services).profile(invocation)
                return (id, services.browserProfiles.record(id)?.name ?? id)
            },
            window: { services.windows.active?.window ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) },
            reveal: { tab in _ = registry.perform("tab.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab), origin: .user)) },
            track: { registry.track($0) }, imported: { services.onboarding.browserImportOffer.importFinished($0) },
            destination: ChromiumCookieDestination { writes, profile in try await cef.importCookies(writes, into: profile) }, isPersonEvent: services.personInput.isPerson, dispatchingEvent: { [inputDispatch = services.inputDispatch] in inputDispatch.event }))
        registry.bind("browser.importCookies", run: { invocation in try cookieImports.run(invocation) })
        // Brings the Import Cookies banner back (Don't Show Again undone) and shows it; it imports nothing.
        registry.bindEffect("browser.showCookieImportBanner", effect: { _ in services.onboarding.browserImportOffer.showNow(); return .done })
        // Import suggestion cards (Settings › Import only): the same import run as the window's.
        ImportSuggestionsCenter.shared.bind(into: registry, host: importCardsHost(services))
        // Every entrypoint previews the exact snapshot and waits for the
        // person's answer before any browser, SSH host or agent is restored.
        registry.bind("workspace.importClassic", run: { _ in
            let window = NSApp.keyWindow ?? NSApp.mainWindow
            registry.track(Task { @MainActor in
                do {
                    _ = try await importClassic(services, in: window)
                    return nil
                } catch {
                    return ActionWorkFailure(log: "import-classic: \(error)", reason: PlainErrorText.words(error))
                }
            })
        })
        registry.bind("palette.makeDefaultTerminal", run: { _ in
            let apps = services.onboarding.defaultApps
            registry.track(Task { @MainActor in
                do {
                    for claim in DefaultHandlerClaim.terminalClaims where !apps.isClaimed(claim) { try await apps.claim(claim) }
                    return nil
                } catch {
                    return (error as? CocoaError)?.code == .userCancelled ? nil : ActionWorkFailure("make-default-terminal", error)
                }
            })
        })
        registry.bind("palette.makeDefaultBrowser", run: { _ in
            let apps = services.onboarding.defaultApps
            registry.track(Task { @MainActor in
                do {
                    try await apps.claim(.webBrowser)
                    return nil
                } catch {
                    // A refusal in the system prompt is not a failure.
                    return (error as? CocoaError)?.code == .userCancelled ? nil : ActionWorkFailure("make-default-browser", error)
                }
            })
        })
    }

    /// What the import cards run through the App: the Import from Browser window's import run,
    /// Import Workspaces from Classic cmux and Import from Conductor.
    static func importCardsHost(_ services: AppServices) -> ImportCardsHost {
        ImportCardsHost(
            runImport: { plan, keys, progress in try await AppOnboardingServices(owner: services.onboarding).runImport(plan, keys: keys, progress: progress) },
            importedProfiles: { Set(await services.onboarding.importStore.sources().map(\.sourceKey)) },
            openSettings: { route in try? services.settingsWindow.show(section: nil, route: route) },
            importClassic: { progress in try await importClassic(services, in: nil, progress: progress)?.opened },
            importConductor: { progress in try await ConductorImport(host: services).run(progress: progress) },
            classicAvailability: {
                guard let reply = try? await AppOnboardingServices(owner: services.onboarding).classicImportClient().probe(.manual),
                      reply.available else { return .unavailable }
                return reply.alreadyImported ? .alreadyImported : .available
            }, detectConductor: { await ConductorImportClient.detect(on: services.daemon.connection) })
    }

    /// Import Workspaces from Classic cmux as every entrypoint runs it (the action, the cmux
    /// Classic card): the import with its preview, then its toast in `window` (the key window
    /// when nil). Returns what it did, nil when the person declined the preview.
    static func importClassic(_ services: AppServices, in window: NSWindow?,
                              progress: (@MainActor (Double) -> Void)? = nil) async throws -> ClassicImportSummary? {
        do {
            guard let summary = try await AppOnboardingServices(owner: services.onboarding).importClassicSessions(progress: progress) else {
                return nil
            }
            let notice = ClassicImportStrings.notice(summary)
            services.onboarding.classicImportNotice = notice
            ClassicImportStrings.toast(notice, in: window)
            return summary
        } catch {
            services.onboarding.classicImportNotice = ClassicImportStrings.failed
            ClassicImportStrings.toast(ClassicImportStrings.failed, in: window)
            throw error
        }
    }
}

enum ClassicImportStrings {
    /// The classic app that saves under `bundle` (a classic bundle id), as its Dock names it.
    static func appName(_ bundle: String) -> String { ClassicImportPreviewStrings.appName(bundle) }
    /// The first launch's toast when cmux-next already had workspaces, so classic's were only recorded.
    static var inUseBefore: String {
        String(localized: "classicImport.toast.inUseBefore",
               defaultValue: "Classic cmux workspaces weren’t imported because this app already had its own. Import them any time from Settings › Import.",
               bundle: .module.inAppLanguage)
    }
    /// The first launch's toast when the classic app named `app` is open, so nothing came over.
    static func classicOpen(_ app: String) -> String {
        let format = String(localized: "classicImport.toast.classicOpen",
                            defaultValue: "%@ (classic) is open, so its workspaces weren’t imported. Quit it and reopen this app, or import them from Settings › Import.",
                            bundle: .module.inAppLanguage)
        return String(format: format, app)
    }
    static var imported: String {
        String(localized: "classicImport.toast.imported", defaultValue: "Workspaces from classic cmux are open.", bundle: .module.inAppLanguage)
    }
    static var allHere: String {
        String(localized: "classicImport.toast.allHere", defaultValue: "Every workspace from classic cmux is already open here.", bundle: .module.inAppLanguage)
    }
    static var nothingSaved: String {
        String(localized: "classicImport.toast.none", defaultValue: "Classic cmux has no saved workspaces to import.", bundle: .module.inAppLanguage)
    }
    static var settingsComplete: String {
        String(localized: "classicImport.toast.settingsComplete", defaultValue: "Classic settings import complete.", bundle: .module.inAppLanguage)
    }
    static var failed: String {
        String(localized: "classicImport.toast.failed", defaultValue: "Couldn’t import workspaces from classic cmux.", bundle: .module.inAppLanguage)
    }
    static var cloudVMsStay: String {
        String(localized: "classicImport.toast.cloudVMsStay",
               defaultValue: "Cloud VM workspaces stay in classic cmux; cmux-next can’t open them yet.", bundle: .module.inAppLanguage)
    }
    static var sshStays: String {
        String(localized: "classicImport.toast.sshStays",
               defaultValue: "SSH workspaces whose host didn’t connect stay in classic cmux.", bundle: .module.inAppLanguage)
    }
    static var sshScrollbackStays: String {
        String(localized: "classicImport.toast.sshScrollbackStays",
               defaultValue: "SSH terminals open without their old scrollback.", bundle: .module.inAppLanguage)
    }
    static var tabsStay: String {
        String(localized: "classicImport.toast.tabsStay",
               defaultValue: "Markdown and file preview tabs stay in classic cmux.", bundle: .module.inAppLanguage)
    }

    /// What opened, then what stayed in classic and why.
    static func notice(_ summary: ClassicImportSummary) -> String {
        if summary.settingsOnly { return settingsComplete }
        let stayed = (summary.leftCloudVMs ? [cloudVMsStay] : []) + (summary.leftSSH ? [sshStays] : [])
            + (summary.leftSSHScrollback ? [sshScrollbackStays] : []) + (summary.leftTabs ? [tabsStay] : [])
        let opened = summary.opened > 0 ? [imported] : summary.alreadyHere > 0 ? [allHere] : stayed.isEmpty ? [nothingSaved] : []
        return (opened + stayed).joined(separator: " ")
    }

    @MainActor static func toast(_ message: String, in window: NSWindow?, importAgain: (() -> Void)? = nil) {
        guard let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        CmuxToastCenter.shared.showClassicImport(message, in: window, importAgain: importAgain)
    }
}
