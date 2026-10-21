import AppKit
import CmuxNextActions
import CmuxNextVSCodeServer
@testable import CmuxNextApp
import Foundation
import Testing

/// VS Code (Inline): Open Folder in VS Code (Inline)… serves the folder from the app's one
/// `serve-web` server and opens it in a browser split; Stop and Restart VS Code Inline Server act on
/// that server. All three run from the palette, the menu, the CLI and MCP (`action run`).
@MainActor @Suite(.serialized)
struct VSCodeInlineActionTests {
    nonisolated static let ids: [ActionID] = ["palette.openFolderInVSCodeInline", "palette.vscodeServeWebStop", "palette.vscodeServeWebRestart"]

    static func services() -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        return services
    }

    @Test(arguments: ids)
    func theActionIsNoLongerGreyedOut(_ id: ActionID) {
        let services = Self.services()
        #expect(services.registry.unavailableReason(for: id) == nil, "\(id) is still bound as unavailable")
    }

    /// Stop with no server running is a no-op that succeeds, from automation too.
    @Test func stopWithNoServerRunningSucceedsFromTheCLI() async {
        let services = Self.services()
        var ran = false
        let refusal = services.registry.capturingRefusal {
            ran = services.registry.perform("palette.vscodeServeWebStop", invocation: ActionInvocation(origin: .cli))
        }
        #expect(ran)
        #expect(refusal == nil)
        #expect(await !services.vscodeServeWeb.isServing)
    }
}
