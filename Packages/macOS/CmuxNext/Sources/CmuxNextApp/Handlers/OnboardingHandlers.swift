import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextCookieImport
import CmuxNextDesign
import CmuxNextImportCards
import CmuxNextOnboarding

/// Import and default-app actions. Import from Browser opens the tool window
/// (`OnboardingService`); Make cmux the Default Terminal asks macOS directly
/// for each handler; Make cmux the Default Browser asks macOS directly
/// (macOS shows its confirmation); Import Workspaces from Classic cmux opens
/// classic's last saved session.
enum OnboardingHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        registry.bind("importFromBrowser", run: { _ in services.onboarding.show(step: .importData) })
        registry.bind("browserProfile.removeImportedData", run: { invocation in
            let record = try context.browserProfile(invocation), sync = services.onboarding.historySync
            let profile = record.id, name = record.name, sink = services.importedBookmarkSink
            let end = registry.completion(on: services.mainWork)
            // One removal the person asked for, on the import store's actor; the toast reports it (or that it
            // failed) as the run's completion.
            end.start {
                let counts = try? await sync.removeImported(profile: profile, bookmarks: sink)
                end.post(owner: "OnboardingHandlers.removeImported", answering: true) {
                    BrowserFileImport.toast(services, id: "browser-import-removed", counts.removalText(profile: name))
                }
            }
        })
        // No path argument: only the person's own pick in the open panel brings passwords in.
        registry.bind("password.importCSV", run: { invocation in
            try PasswordCSVFiles(services: services).chooseImport(profile: BookmarkResolver(services: services).profile(invocation))
        })
        registry.bind("browser.importFromFiles", run: { invocation in
            BrowserFileImport(services: services).run(profile: BookmarkResolver(services: services).profile(invocation))
        })
        // Cookies of one browser profile, for the CLI and agents: an agent's run asks the person first.
        let cef = services.cache.cef
        let cookieImports = CookieImportService(host: CookieImportHost(
            requester: { invocation in
                let agentTabs = services.agentTabs
                let tabs = services.daemon.store.workspaces.flatMap { workspace in
                    workspace.screens.flatMap(\.panes).flatMap(\.tabs).map { tab in
                        CookieImportCandidate(tabID: tab.id, title: tab.displayTitle, workspace: workspace.displayName,
                                              agentSession: agentTabs.sessions[agentTabs.resolve(tab.id)] ?? tab.agentSession?.session,
                                              terminalIDs: [tab.terminalID?.rawValue, tab.terminalResourceID?.rawValue].compactMap(\.self))
                    }
                }
                return CookieImportRequester(invocation, among: tabs) { session in
                    services.chatsFeed?.chats.first { $0.sessionID == session }.map { ($0.title, $0.preview) }
                }
            },
            target: { invocation in
                let id = BookmarkResolver(services: services).profile(invocation)
                return (id, services.browserProfiles.record(id)?.name ?? id)
            },
            window: { services.windows.active?.window ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) },
            reveal: { tab in _ = registry.perform("tab.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab), origin: .user)) },
            track: { registry.track($0) },
            destination: ChromiumCookieDestination { writes, profile in try await cef.importCookies(writes, into: profile) },
            deadlines: services.mainDeadlines))
        registry.bind("browser.importCookies", run: { invocation in try cookieImports.run(invocation) })
        // Import suggestion cards (Settings › Import only): the same import run as the window's.
        ImportSuggestionsCenter.shared.bind(into: registry, host: importCardsHost(services))
        // Every entrypoint previews the exact snapshot and waits for the
        // person's answer before any browser, SSH host or agent is restored.
        // The preview and the person's answer are awaited off main; the run's result is one task on main.
        registry.bind("workspace.importClassic", run: { _ in
            let window = NSApp.keyWindow ?? NSApp.mainWindow
            registry.trackWork(owner: "OnboardingHandlers.importClassic", on: services.mainWork) {
                _ = try await importClassic(services, in: window)
            } then: { result in
                guard case .failure(let error) = result else { return nil }
                return ActionWorkFailure("import-classic: \(error)")
            }
        })
        registry.bind("palette.makeDefaultTerminal", run: { _ in
            registry.trackWork(owner: "OnboardingHandlers.makeDefaultTerminal", on: services.mainWork) {
                try await claimDefaults(terminal: true, services)
            } then: { result in
                defaultFailure(result, label: "make-default-terminal")
            }
        })
        registry.bind("palette.makeDefaultBrowser", run: { _ in
            registry.trackWork(owner: "OnboardingHandlers.makeDefaultBrowser", on: services.mainWork) {
                try await claimDefaults(terminal: false, services)
            } then: { result in
                defaultFailure(result, label: "make-default-browser")
            }
        })
    }

    /// Makes cmux the default terminal (each handler not cmux's yet) or the default browser; macOS asks
    /// the person to confirm the browser.
    private static func claimDefaults(terminal: Bool, _ services: AppServices) async throws {
        let apps = services.onboarding.defaultApps
        guard terminal else { return try await apps.claim(.webBrowser) }
        for claim in DefaultHandlerClaim.terminalClaims {
            let claimed = await apps.isClaimed(claim)
            if !claimed { try await apps.claim(claim) }
        }
    }

    /// A default-app claim's failure; a refusal in the system prompt is not one.
    private static func defaultFailure(_ result: Result<Void, any Error>, label: String) -> ActionWorkFailure? {
        guard case .failure(let error) = result, (error as? CocoaError)?.code != .userCancelled else { return nil }
        return ActionWorkFailure(label, error)
    }

    /// What the import cards run through the App: the Import from Browser window's import run
    /// and Import Workspaces from Classic cmux.
    static func importCardsHost(_ services: AppServices) -> ImportCardsHost {
        ImportCardsHost(
            runImport: { plan, keys, progress in try await AppOnboardingServices(owner: services.onboarding).runImport(plan, keys: keys, progress: progress) },
            importedProfiles: { Set(await services.onboarding.importStore.sources().map(\.sourceKey)) },
            openSettings: { route in try? services.settingsWindow.show(section: nil, route: route) },
            importClassic: { progress in try await importClassic(services, in: nil, progress: progress)?.opened },
            appEvents: services.appEvents)
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
    static var previewTitle: String {
        String(localized: "classicImport.preview.title", defaultValue: "Import these classic workspaces?", bundle: .module)
    }
    static var previewButton: String {
        String(localized: "classicImport.preview.button", defaultValue: "Import", bundle: .module)
    }
    static func previewLines(_ plan: ClassicImportPlan) -> [String] {
        let format = String(
            localized: "classicImport.preview.summary",
            defaultValue: "Source: %1$@\nWorkspaces: %2$@\nBrowser tabs: %3$@\nLocal file pages: %4$@\nSSH workspaces: %5$@\nAgent chats: %6$@\nCloud VM workspaces skipped: %7$@\nImporting loads saved browser pages, connects to saved SSH hosts, and resumes saved agent chats.",
            bundle: .module
        )
        // The localized text uses fixed field labels; only the values vary.
        // Format those numbers for the person's locale before substitution.
        let text = String(
            format: format, plan.source.fileName, plan.workspaces.count.formatted(.number),
            plan.browserTabs.formatted(.number), plan.localFilePages.formatted(.number),
            plan.sshWorkspaces.formatted(.number), plan.agentChats.formatted(.number),
            plan.skippedCloudVMs.formatted(.number)
        )
        let cleanupFormat = String(
            localized: "classicImport.preview.cleanup",
            defaultValue: "Interrupted workspaces to replace (their terminals will end): %1$@",
            bundle: .module
        )
        let cleanup = String(format: cleanupFormat, plan.cleanupWorkspaces.formatted(.number))
        return text.components(separatedBy: "\n") + [cleanup]
    }
    static var imported: String {
        String(localized: "classicImport.toast.imported", defaultValue: "Workspaces from classic cmux are open.", bundle: .module)
    }
    static var allHere: String {
        String(localized: "classicImport.toast.allHere", defaultValue: "Every workspace from classic cmux is already open here.", bundle: .module)
    }
    static var nothingSaved: String {
        String(localized: "classicImport.toast.none", defaultValue: "Classic cmux has no saved workspaces to import.", bundle: .module)
    }
    static var failed: String {
        String(localized: "classicImport.toast.failed", defaultValue: "Couldn’t import workspaces from classic cmux.", bundle: .module)
    }
    static var cloudVMsStay: String {
        String(localized: "classicImport.toast.cloudVMsStay",
               defaultValue: "Cloud VM workspaces stay in classic cmux; cmux-next can’t open them yet.", bundle: .module)
    }
    static var sshStays: String {
        String(localized: "classicImport.toast.sshStays",
               defaultValue: "SSH workspaces whose host didn’t connect stay in classic cmux.", bundle: .module)
    }
    static var sshScrollbackStays: String {
        String(localized: "classicImport.toast.sshScrollbackStays",
               defaultValue: "SSH terminals open without their old scrollback.", bundle: .module)
    }
    static var tabsStay: String {
        String(localized: "classicImport.toast.tabsStay",
               defaultValue: "Markdown and file preview tabs stay in classic cmux.", bundle: .module)
    }

    /// What opened, then what stayed in classic and why.
    static func notice(_ summary: ClassicImportSummary) -> String {
        let stayed = (summary.leftCloudVMs ? [cloudVMsStay] : []) + (summary.leftSSH ? [sshStays] : [])
            + (summary.leftSSHScrollback ? [sshScrollbackStays] : []) + (summary.leftTabs ? [tabsStay] : [])
        let opened = summary.opened > 0 ? [imported] : summary.alreadyHere > 0 ? [allHere] : stayed.isEmpty ? [nothingSaved] : []
        return (opened + stayed).joined(separator: " ")
    }

    @MainActor static func toast(_ message: String, in window: NSWindow?) {
        guard let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        _ = CmuxToastCenter.shared.show(CmuxToast(id: "classicImport", message: message), in: window)
    }
}
