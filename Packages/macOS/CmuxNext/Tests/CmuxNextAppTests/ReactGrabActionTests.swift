import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// Toggle React Grab is a working action on every entrypoint (palette, View menu, keyboard, and
/// `cmux browser toggle-react-grab` / MCP through `action run`), not a greyed-out row.
@MainActor @Suite(.serialized)
struct ReactGrabActionTests {
    @Test func toggleReactGrabIsAvailable() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        #expect(services.registry.unavailableReason(for: "toggleReactGrab") == nil)
    }
}
