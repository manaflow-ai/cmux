import AppKit
import CmuxNextActions
import CmuxNextOnboarding

/// Onboarding and default-app actions. The palette, the app menu and the
/// CLI open the same window (`OnboardingService`); Import Browser Data and
/// Make cmux the Default Terminal asks macOS directly for each handler. Make cmux the
/// Default Browser asks macOS directly (macOS shows its confirmation).
enum OnboardingHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        registry.bind("palette.welcomeChecklist", run: { _ in services.onboarding.show() })
        // Help menu, palette and Settings: one handler.
        registry.bind("onboarding.continueSetup", run: { _ in services.onboarding.continueSetup() })
        registry.bind("palette.importClassicSessions", run: { _ in services.onboarding.show(step: .classicSessions) })
        registry.bind("importAndSync.show", run: { _ in services.onboarding.show() })
        registry.bind("palette.onboardingGallery", run: { _ in services.onboarding.showGallery() })
        registry.bind("importFromBrowser", run: { _ in services.onboarding.show(step: .importData) })
        // No path argument: only the person's own pick in the open panel brings passwords in.
        registry.bind("password.importCSV", run: { invocation in
            try PasswordCSVFiles(services: services).chooseImport(profile: BookmarkResolver(services: services).profile(invocation))
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
