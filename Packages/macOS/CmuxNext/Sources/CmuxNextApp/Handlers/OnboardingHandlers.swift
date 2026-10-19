import AppKit
import CmuxNextActions
import CmuxNextDesign
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
        // No path argument: only the person's own pick in the open panel brings passwords in.
        registry.bind("password.importCSV", run: { invocation in
            try PasswordCSVFiles(services: services).chooseImport(profile: BookmarkResolver(services: services).profile(invocation))
        })
        registry.bind("browser.importFromFiles", run: { invocation in
            BrowserFileImport(services: services).run(profile: BookmarkResolver(services: services).profile(invocation))
        })
        // Cookies of one browser profile, for the CLI and agents: an agent's run asks the person first.
        let cookieImports = CookieImportService(services: services)
        registry.bind("browser.importCookies", run: { invocation in try cookieImports.run(invocation) })
        // A toast, never a sheet: the person can keep working while it runs.
        registry.bind("workspace.importClassic", run: { _ in
            let window = NSApp.keyWindow ?? NSApp.mainWindow
            registry.track(Task { @MainActor in
                do {
                    let summary = try await AppOnboardingServices(owner: services.onboarding).importClassicSessions()
                    let notice = ClassicImportStrings.notice(summary)
                    services.onboarding.classicImportNotice = notice
                    ClassicImportStrings.toast(notice, in: window)
                    return nil
                } catch {
                    services.onboarding.classicImportNotice = ClassicImportStrings.failed
                    ClassicImportStrings.toast(ClassicImportStrings.failed, in: window)
                    return ActionWorkFailure("import-classic: \(error)")
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
}

enum ClassicImportStrings {
    static var imported: String {
        String(localized: "classicImport.toast.imported", defaultValue: "Workspaces from classic cmux are open.", bundle: .module)
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
        let opened = summary.opened > 0 ? [imported] : stayed.isEmpty ? [nothingSaved] : []
        return (opened + stayed).joined(separator: " ")
    }

    @MainActor static func toast(_ message: String, in window: NSWindow?) {
        guard let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        _ = CmuxToastCenter.shared.show(CmuxToast(id: "classicImport", message: message), in: window)
    }
}
