import AppKit
import CmuxNextActions
import CmuxNextOnboarding

/// Onboarding and default-app actions. The palette, the app menu and the
/// CLI open the same window (`OnboardingService`); Import Browser Data and
/// Make cmux the Default Terminal open it at their step. Make cmux the
/// Default Browser asks macOS directly (macOS shows its confirmation).
enum OnboardingHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        registry.bind("palette.welcomeChecklist", run: { _ in services.onboarding.show() })
        registry.bind("importFromBrowser", run: { _ in services.onboarding.show(step: .importData) })
        registry.bind("palette.makeDefaultTerminal", run: { _ in services.onboarding.show(step: .defaultTerminal) })
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
