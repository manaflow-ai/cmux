import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// `permissions.request` over the control socket refuses a request the
/// card could not show honestly: an unknown kind, no reason, automation
/// without the app to control, a timeout out of range. It refuses before
/// any card shows or any grant is read.
@MainActor @Suite(.serialized) struct PermissionsControlTests {
    private func router() -> ControlRouter {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let router = ControlRouter(identity: ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test", tag: "test",
                                                             processID: getpid()),
                                   executor: RegistryControlBridge(registry: services.registry), settings: nil,
                                   configuration: ControlRouter.Configuration(requestDeadline: .seconds(30)))
        router.register(PermissionsControl.methods(services: services))
        return router
    }

    private func code(_ params: [String: JSONValue]) async -> String? {
        let result = await router().handle(ControlRequest(id: "1", method: "permissions.request", params: params))
        guard case .failure(let error) = result else { return nil }
        return error.code
    }

    @Test func anUnknownKindIsRefused() async {
        #expect(await code(["kind": "everything", "reason": "Read every file on the disk"]) == "invalid_params")
    }

    @Test func aRequestWithoutAReasonIsRefused() async {
        #expect(await code(["kind": "full_disk_access"]) == "invalid_params")
        #expect(await code(["kind": "full_disk_access", "reason": "need"]) == "invalid_params")
    }

    @Test func automationWithoutATargetIsRefused() async {
        #expect(await code(["kind": "automation", "reason": "Make a playlist in Music"]) == "invalid_params")
    }

    @Test func aTimeoutOutOfRangeIsRefused() async {
        #expect(await code(["kind": "camera", "reason": "Scan the QR code on the desk", "timeout_seconds": 0]) == "invalid_params")
        #expect(await code(["kind": "camera", "reason": "Scan the QR code on the desk", "timeout_seconds": 601]) == "invalid_params")
    }
}
