import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Foundation
import Testing

/// Restore Previous App Launch (`reopenPreviousSession`, Cmd-Shift-O, `workspace
/// restore-previous-app-launch`): the windows open when the app last quit come back at launch;
/// this action reopens the ones of them closed since, and the workspaces closed since from them,
/// through the daemon's closed history (the one reopen path).
@MainActor @Suite(.serialized)
struct RestorePreviousLaunchTests {
    static func services() -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        return services
    }

    @Test func restorePreviousAppLaunchIsAnAvailableAction() {
        let services = Self.services()
        #expect(services.registry.unavailableReason(for: "reopenPreviousSession") == nil)
    }

    /// A launch that restored nothing (no saved windows): nothing to reopen, said in words.
    @Test func withNothingFromThePreviousLaunchItRefusesWithAReason() {
        let services = Self.services()
        let refusal = services.registry.capturingRefusal {
            _ = services.registry.perform("reopenPreviousSession", invocation: ActionInvocation(origin: .cli))
        }
        #expect(refusal == "Nothing from the previous app launch to restore")
    }
}
