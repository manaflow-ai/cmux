import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextControl
@testable import CmuxNextNotifications
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
        let router = makeRouter(ControlMethod.notifications { center })

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
        let router = makeRouter(ControlMethod.notifications { center })
        let after = try await router.handle(ControlRequest(id: "1", method: "notifications.request", params: [:])).get()
        #expect(after.objectValue?["authorization"] == .string("denied"), "\(after)")
    }

    @Test func aHostThatIsNotTheAppBundleAnswersUnavailable() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let router = makeRouter(ControlMethod.notifications(services: services))
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

    // MARK: notifications.banners and notifications.open (release builds, the notify-banner-click probe)

    /// A router like a release build's: no `debug.*` method is served.
    private func makeReleaseRouter(_ services: AppServices) -> ControlRouter {
        let router = ControlRouter(identity: ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.nightly", tag: "test",
                                                             processID: getpid()),
                                   executor: RegistryControlBridge(registry: ActionRegistry(catalog: [])), settings: nil,
                                   configuration: ControlRouter.Configuration(requestDeadline: .seconds(30), allowsDebugMethods: false))
        router.register(ControlMethod.notifications(services: services))
        return router
    }

    private func appServices() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }

    @Test func aReleaseRouterListsThePostedBannersNewestLast() async throws {
        let services = appServices()
        let router = makeReleaseRouter(services)
        let desktop = services.notifications.desktop
        desktop.post(id: "older", title: "Claude finished", body: "first turn", surface: 3, workspace: nil, defaultSound: false)
        desktop.post(id: "newer", title: "Claude needs you", subtitle: "repo", body: "second turn", surface: 7, workspace: nil,
                     defaultSound: false, reply: true)

        let answer = try await router.handle(ControlRequest(id: "1", method: "notifications.banners", params: [:])).get()
        let banners = try #require(answer.objectValue?["banners"]?.arrayValue, "\(answer)")
        #expect(banners.compactMap { $0.objectValue?["id"]?.stringValue }.suffix(2) == ["older", "newer"], "\(answer)")
        let newest = try #require(banners.last?.objectValue)
        #expect(newest["title"] == .string("Claude needs you"))
        #expect(newest["subtitle"] == .string("repo"))
        #expect(newest["body"] == .string("second turn"))
        #expect(newest["surface"] == .number(7))
        #expect(newest["reply"] == .bool(true))
        #expect(newest["approval"] == .bool(false))
        #expect(newest["category"] == .string(DesktopNotifier.replyCategory))
        #expect(newest["attachment"] == nil, "the release list carries no badge PNG: \(newest)")
        #expect(answer.objectValue?["authorization"]?.stringValue != nil, "\(answer)")
        withExtendedLifetime(services) {}
    }

    @Test func openingABannerRunsItsClickOnItsOwnSurface() async throws {
        let services = appServices()
        let router = makeReleaseRouter(services)
        let desktop = services.notifications.desktop
        var opened: [(String, UInt64?)] = []
        desktop.onOpenTab = { id, surface in opened.append((id, surface)) }
        var clicks = 0
        desktop.onOpen = { _, _ in clicks += 1 }
        desktop.post(id: "cmux-notification-9", title: "Claude finished", body: "", surface: 9, workspace: nil, defaultSound: false)

        // A caller-named surface is ignored: the banner's own surface is the one opened.
        let answer = try await router.handle(ControlRequest(id: "1", method: "notifications.open",
                                                            params: ["id": .string("cmux-notification-9"), "surface": .number(1)])).get()
        #expect(answer.objectValue?["opened"] == .string("cmux-notification-9"), "\(answer)")
        #expect(answer.objectValue?["surface"] == .number(9), "\(answer)")
        #expect(opened.count == 1)
        #expect(opened.first?.0 == "cmux-notification-9")
        #expect(opened.first?.1 == 9)
        #expect(clicks == 0, "a script's open ran the whole click route (a page's handler, a special banner's route)")
        withExtendedLifetime(services) {}
    }

    @Test func anUnknownBannerIsNotFoundAndOpensNothing() async throws {
        let services = appServices()
        let router = makeReleaseRouter(services)
        let desktop = services.notifications.desktop
        var opened = 0
        desktop.onOpen = { _, _ in opened += 1 }
        desktop.onOpenTab = { _, _ in opened += 1 }
        desktop.post(id: "cmux-notification-9", title: "Claude finished", body: "", surface: 9, workspace: nil, defaultSound: false)

        for params: [String: JSONValue] in [["id": .string("no-such-banner")], [:]] {
            let result = await router.handle(ControlRequest(id: "1", method: "notifications.open", params: params))
            guard case .failure(let error) = result else {
                Issue.record("notifications.open \(params) answered \(result)")
                continue
            }
            #expect(error.code == (params.isEmpty ? "invalid_params" : "not_found"), "\(params): \(error)")
        }
        #expect(opened == 0, "a refused open ran the banner click")
        withExtendedLifetime(services) {}
    }

    /// A passkey banner's click starts a WebAuthn ceremony, which runs only on the person's own click
    /// (agent-browser-passkey-DESIGN.md); the other special banners (iPhone pairing, attention, Runs,
    /// a page's notification) likewise act on the person's intent. A script's open runs none of them.
    @Test func aScriptCannotClickAPasskeyOrOtherSpecialBanner() async throws {
        let services = appServices()
        let router = makeReleaseRouter(services)
        let desktop = services.notifications.desktop
        var opened = 0, passkeys = 0
        desktop.onOpen = { _, _ in opened += 1 }
        desktop.onOpenTab = { _, _ in opened += 1 }
        services.notifications.onPasskeyBanner = { _ in passkeys += 1 }
        let special = ["cmux-passkey-\(UUID().uuidString)", "cmux-attention.tab_1", "handoff.1", "sandbox-run.1"]
        for id in special {
            desktop.post(id: id, title: "Sign in", body: "", surface: 9, workspace: nil, defaultSound: false)
            let result = await router.handle(ControlRequest(id: "1", method: "notifications.open", params: ["id": .string(id)]))
            guard case .failure(let error) = result else {
                Issue.record("notifications.open \(id) answered \(result)")
                continue
            }
            #expect(error.code == "person_required", "\(id): \(error)")
        }
        #expect(opened == 0, "a script's open ran a special banner's click")
        #expect(passkeys == 0, "a script's open started a passkey ceremony")
        withExtendedLifetime(services) {}
    }

    /// An incognito window's banner names nothing of the window: not its tab's surface either.
    @Test func anIncognitoBannerIsListedWithoutItsSurface() async throws {
        let services = appServices()
        let router = makeReleaseRouter(services)
        services.notifications.desktop.post(id: "cmux-notification-4", title: "Claude finished", body: "secret", surface: 4,
                                            workspace: nil, defaultSound: false, incognito: true)
        let answer = try await router.handle(ControlRequest(id: "1", method: "notifications.banners", params: [:])).get()
        let banner = try #require(answer.objectValue?["banners"]?.arrayValue?.last?.objectValue, "\(answer)")
        #expect(banner["id"] == .string("cmux-notification-4"))
        #expect(banner["surface"] == .null, "\(banner)")
        #expect(banner["body"] != .string("secret"), "\(banner)")
        withExtendedLifetime(services) {}
    }
}
