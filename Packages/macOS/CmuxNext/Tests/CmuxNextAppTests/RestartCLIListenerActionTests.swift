import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Foundation
import Testing

/// Restart CLI Listener (`palette.restartSocketListener`, the palette and
/// `cmux settings restart-cli-listener`): it runs the app's control socket
/// restart instead of showing a greyed-out reason, and says why when the app
/// has no listener to restart.
@MainActor @Suite(.serialized)
struct RestartCLIListenerActionTests {
    @Test func restartCLIListenerRestartsTheAppsControlSocket() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        #expect(services.registry.unavailableReason(for: "palette.restartSocketListener") == nil,
                "Restart CLI Listener is still greyed out")
        var restarts = 0
        services.restartControlListener = { restarts += 1 }
        let refusal = services.registry.capturingRefusal {
            _ = services.registry.perform("palette.restartSocketListener", invocation: ActionInvocation())
        }
        #expect(refusal == nil)
        #expect(restarts == 1)
    }

    @Test func restartCLIListenerExplainsAMissingListener() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.restartControlListener = nil
        let refusal = services.registry.capturingRefusal {
            _ = services.registry.perform("palette.restartSocketListener", invocation: ActionInvocation())
        }
        #expect(refusal != nil, "a run with no listener did nothing silently")
    }
}
