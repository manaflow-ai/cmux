import Foundation
import Testing
@testable import CmuxControlSocket

/// A scriptable ``ControlCommandContext`` for driving the unsupported/network
/// browser methods. The per-surface unsupported-network-request log is recorded
/// in memory, mirroring the app-side ring buffer the coordinator reaches through
/// the ``ControlBrowserContext`` seam.
@MainActor
private final class FakeBrowserUnsupportedContext: ControlCommandContext {
    private(set) var recorded: [UUID: [JSONValue]] = [:]

    func controlBrowserRecordUnsupportedNetworkRequest(
        surfaceID: UUID,
        action: String,
        params: [String: JSONValue]
    ) {
        recorded[surfaceID, default: []].append(
            .object(["action": .string(action), "params": .object(params)])
        )
    }

    func controlBrowserUnsupportedNetworkRequests(surfaceID: UUID) -> [JSONValue] {
        recorded[surfaceID] ?? []
    }
}

@MainActor
@Suite("ControlCommandCoordinator browser unsupported domain")
struct ControlCommandCoordinatorBrowserUnsupportedTests {
    private func makeCoordinator() -> (ControlCommandCoordinator, FakeBrowserUnsupportedContext) {
        let context = FakeBrowserUnsupportedContext()
        return (ControlCommandCoordinator(context: context), context)
    }

    private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }

    /// Every pure stub reports the exact legacy `not_supported` code/message and
    /// a `details`-only data payload.
    @Test func pureStubsReportNotSupported() {
        let (coordinator, _) = makeCoordinator()
        let cases: [(method: String, details: String)] = [
            ("browser.viewport.set", "WKWebView does not provide a per-tab programmable viewport emulation API equivalent to CDP"),
            ("browser.geolocation.set", "WKWebView does not expose per-tab geolocation spoofing hooks equivalent to Playwright/CDP"),
            ("browser.offline.set", "WKWebView does not expose reliable per-tab offline emulation"),
            ("browser.trace.start", "Playwright trace artifacts are not available on WKWebView"),
            ("browser.trace.stop", "Playwright trace artifacts are not available on WKWebView"),
            ("browser.screencast.start", "WKWebView does not expose CDP screencast streaming"),
            ("browser.screencast.stop", "WKWebView does not expose CDP screencast streaming"),
            ("browser.input_mouse", "Raw CDP mouse injection is unavailable; use browser.click/hover/scroll"),
            ("browser.input_keyboard", "Raw CDP keyboard injection is unavailable; use browser.press/keydown/keyup"),
            ("browser.input_touch", "Raw CDP touch injection is unavailable on WKWebView"),
        ]
        for entry in cases {
            guard case .err(let code, let message, let data)? = coordinator.handle(request(entry.method)) else {
                Issue.record("\(entry.method) did not return an error result")
                continue
            }
            #expect(code == "not_supported")
            #expect(message == "\(entry.method) is not supported on WKWebView")
            #expect(data == .object(["details": .string(entry.details)]))
        }
    }

    /// `network.route`/`unroute` record the attempt for a resolvable surface and
    /// still report not-supported.
    @Test func networkRouteRecordsAndReportsNotSupported() {
        let (coordinator, context) = makeCoordinator()
        let surfaceID = UUID()
        let params: [String: JSONValue] = [
            "surface_id": .string(surfaceID.uuidString),
            "url": .string("https://example.com/*"),
        ]
        guard case .err(let code, let message, _)? = coordinator.handle(request("browser.network.route", params)) else {
            Issue.record("network.route did not return an error result")
            return
        }
        #expect(code == "not_supported")
        #expect(message == "browser.network.route is not supported on WKWebView")
        #expect(context.recorded[surfaceID]?.count == 1)
        #expect(context.recorded[surfaceID]?.first == .object([
            "action": .string("route"),
            "params": .object(params),
        ]))

        _ = coordinator.handle(request("browser.network.unroute", params))
        #expect(context.recorded[surfaceID]?.count == 2)
        #expect(context.recorded[surfaceID]?.last == .object([
            "action": .string("unroute"),
            "params": .object(params),
        ]))
    }

    /// Without a resolvable `surface_id`, nothing is recorded.
    @Test func networkRouteWithoutSurfaceRecordsNothing() {
        let (coordinator, context) = makeCoordinator()
        _ = coordinator.handle(request("browser.network.route"))
        #expect(context.recorded.isEmpty)
    }

    /// `network.requests` returns the recorded log inside the not-supported error
    /// data for a resolvable surface.
    @Test func networkRequestsReturnsRecordedLog() {
        let (coordinator, context) = makeCoordinator()
        let surfaceID = UUID()
        let routeParams: [String: JSONValue] = ["surface_id": .string(surfaceID.uuidString)]
        _ = coordinator.handle(request("browser.network.route", routeParams))

        guard case .err(let code, let message, let data)? = coordinator.handle(
            request("browser.network.requests", ["surface_id": .string(surfaceID.uuidString)])
        ) else {
            Issue.record("network.requests did not return an error result")
            return
        }
        #expect(code == "not_supported")
        #expect(message == "browser.network.requests is not supported on WKWebView")
        #expect(data == .object([
            "details": .string("Request interception logs are unavailable without CDP network hooks"),
            "recorded_requests": .array(context.recorded[surfaceID] ?? []),
        ]))
    }

    /// `network.requests` without a resolvable surface returns the plain
    /// not-supported stub (no `recorded_requests`).
    @Test func networkRequestsWithoutSurfaceReportsPlainStub() {
        let (coordinator, _) = makeCoordinator()
        guard case .err(_, _, let data)? = coordinator.handle(request("browser.network.requests")) else {
            Issue.record("network.requests did not return an error result")
            return
        }
        #expect(data == .object([
            "details": .string("Request interception logs are unavailable without CDP network hooks")
        ]))
    }
}
