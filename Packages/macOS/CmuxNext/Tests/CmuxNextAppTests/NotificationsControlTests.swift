import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// `notifications.status` and `notifications.request` over the control socket (`cmux setup
/// notifications`): the status read never asks, the request asks once and answers the status
/// after, and a launch that never uses the system center (a test host is not the app bundle)
/// answers `unavailable` instead of prompting.
@MainActor @Suite(.serialized) struct NotificationsControlTests {
    /// A permission the person answers with `answer` on the first request.
    actor FakeCenter: NotificationPermissionCenter {
        var current = NotificationPermission(authorization: "not_determined", alert: false, alertStyle: "none", sound: false, badge: false,
                                             bundleID: "com.cmuxterm.app")
        let answer: Bool
        private(set) var requests = 0

        init(answer: Bool) { self.answer = answer }

        func status() async -> NotificationPermission { current }

        func request() async throws -> NotificationPermission {
            requests += 1
            if current.authorization == "not_determined" {
                current.authorization = answer ? "authorized" : "denied"
                (current.alert, current.sound, current.badge) = (answer, answer, answer)
                current.alertStyle = answer ? "banner" : "none"
            }
            return current
        }
    }

    private func makeRouter(_ methods: [ControlMethod]) -> ControlRouter {
        let router = ControlRouter(identity: ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test", tag: "test",
                                                             processID: getpid()),
                                   executor: RegistryControlBridge(registry: ActionRegistry(catalog: [])), settings: nil,
                                   configuration: ControlRouter.Configuration(requestDeadline: .seconds(30)))
        router.register(methods)
        return router
    }

    @Test func theStatusReadNeverAsksAndTheRequestAsksOnce() async throws {
        let center = FakeCenter(answer: true)
        let router = makeRouter(NotificationsControl.methods { center })

        let before = try await router.handle(ControlRequest(id: "1", method: "notifications.status", params: [:])).get()
        #expect(before.objectValue?["authorization"] == .string("not_determined"), "\(before)")
        #expect(before.objectValue?["bundle_id"] == .string("com.cmuxterm.app"), "\(before)")
        #expect(before.objectValue?["alert_style"] == .string("none"), "\(before)")
        #expect(await center.requests == 0)

        let after = try await router.handle(ControlRequest(id: "2", method: "notifications.request", params: [:])).get()
        #expect(after.objectValue?["authorization"] == .string("authorized"), "\(after)")
        #expect(after.objectValue?["alert"] == .bool(true), "\(after)")
        #expect(after.objectValue?["alert_style"] == .string("banner"), "\(after)")
        #expect(await center.requests == 1)
    }

    @Test func aDeclinedPromptAnswersDenied() async throws {
        let center = FakeCenter(answer: false)
        let router = makeRouter(NotificationsControl.methods { center })
        let after = try await router.handle(ControlRequest(id: "1", method: "notifications.request", params: [:])).get()
        #expect(after.objectValue?["authorization"] == .string("denied"), "\(after)")
    }

    @Test func aHostThatIsNotTheAppBundleAnswersUnavailable() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let router = makeRouter(NotificationsControl.methods(services: services))
        for method in ["notifications.status", "notifications.request"] {
            let result = await router.handle(ControlRequest(id: "1", method: method, params: [:]))
            guard case .failure(let error) = result else {
                Issue.record("\(method) answered \(result) in a test host")
                continue
            }
            #expect(error.code == "unavailable", "\(method): \(error)")
        }
        // The methods hold `services` weakly: keep it alive across both calls.
        withExtendedLifetime(services) {}
    }
}
