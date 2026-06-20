import Foundation
import Testing
@testable import CmuxControlSocket

/// A scriptable ``ControlBrowserNavigationReading`` for driving
/// ``ControlBrowserNavigationWorker`` without the app target or a live browser
/// surface. Returns a fixed resolution and records the request it was handed.
private final class FakeBrowserNavigationReading: ControlBrowserNavigationReading, @unchecked Sendable {
    var resolution: ControlBrowserNavigationResolution
    private(set) var lastRequest: ControlBrowserNavigationRequest?

    init(resolution: ControlBrowserNavigationResolution) {
        self.resolution = resolution
    }

    func resolveNavigation(_ request: ControlBrowserNavigationRequest) -> ControlBrowserNavigationResolution {
        lastRequest = request
        return resolution
    }
}

private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
    ControlRequest(id: .string("1"), method: method, params: params)
}

private let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
private let surfaceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
private let windowID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

private func navigated(
    windowID: UUID? = windowID,
    windowRef: String? = "window:1",
    postSnapshot: [String: JSONValue] = [:]
) -> ControlBrowserNavigated {
    ControlBrowserNavigated(
        workspaceID: workspaceID,
        workspaceRef: "workspace:1",
        surfaceID: surfaceID,
        surfaceRef: "surface:1",
        windowID: windowID,
        windowRef: windowRef,
        postSnapshot: postSnapshot
    )
}

@Suite struct ControlBrowserNavigationWorkerTests {
    @Test func returnsNilForNonNavigationMethod() {
        let worker = ControlBrowserNavigationWorker(
            reading: FakeBrowserNavigationReading(resolution: .tabManagerUnavailable)
        )
        #expect(worker.handle(request("browser.snapshot")) == nil)
        #expect(worker.handle(request("browser.eval")) == nil)
    }

    // MARK: - param forwarding

    @Test func navigateParsesAndForwardsURL() {
        let reading = FakeBrowserNavigationReading(resolution: .navigated(navigated()))
        let worker = ControlBrowserNavigationWorker(reading: reading)
        _ = worker.handle(request("browser.navigate", ["url": .string("  https://example.com  ")]))
        guard case .navigate(_, let url)? = reading.lastRequest else {
            Issue.record("expected .navigate request")
            return
        }
        #expect(url == "https://example.com")
    }

    @Test func navigateWhitespaceURLIsTreatedAsAbsent() {
        let reading = FakeBrowserNavigationReading(resolution: .missingURL)
        let worker = ControlBrowserNavigationWorker(reading: reading)
        _ = worker.handle(request("browser.navigate", ["url": .string("   ")]))
        guard case .navigate(_, let url)? = reading.lastRequest else {
            Issue.record("expected .navigate request")
            return
        }
        #expect(url == nil)
    }

    @Test func backForwardReloadMapToTheirCases() {
        let reading = FakeBrowserNavigationReading(resolution: .tabManagerUnavailable)
        let worker = ControlBrowserNavigationWorker(reading: reading)

        _ = worker.handle(request("browser.back"))
        guard case .back? = reading.lastRequest else { Issue.record("expected .back"); return }

        _ = worker.handle(request("browser.forward"))
        guard case .forward? = reading.lastRequest else { Issue.record("expected .forward"); return }

        _ = worker.handle(request("browser.reload"))
        guard case .reload? = reading.lastRequest else { Issue.record("expected .reload"); return }
    }

    // MARK: - error shaping

    @Test func tabManagerUnavailableShapesError() {
        let worker = ControlBrowserNavigationWorker(
            reading: FakeBrowserNavigationReading(resolution: .tabManagerUnavailable)
        )
        #expect(worker.handle(request("browser.reload")) == .err(
            code: "unavailable", message: "TabManager not available", data: nil
        ))
    }

    @Test func invalidSurfaceIDShapesError() {
        let worker = ControlBrowserNavigationWorker(
            reading: FakeBrowserNavigationReading(resolution: .invalidSurfaceID)
        )
        #expect(worker.handle(request("browser.back")) == .err(
            code: "invalid_params", message: "Missing or invalid surface_id", data: nil
        ))
    }

    @Test func missingURLShapesError() {
        let worker = ControlBrowserNavigationWorker(
            reading: FakeBrowserNavigationReading(resolution: .missingURL)
        )
        #expect(worker.handle(request("browser.navigate")) == .err(
            code: "invalid_params", message: "Missing url", data: nil
        ))
    }

    @Test func surfaceNotFoundCarriesSurfaceID() {
        let worker = ControlBrowserNavigationWorker(
            reading: FakeBrowserNavigationReading(resolution: .surfaceNotFound(surfaceID: surfaceID))
        )
        #expect(worker.handle(request("browser.reload")) == .err(
            code: "not_found",
            message: "Surface not found or not a browser",
            data: .object(["surface_id": .string(surfaceID.uuidString)])
        ))
    }

    // MARK: - success shaping

    @Test func navigatedShapesIdentityPayload() {
        let worker = ControlBrowserNavigationWorker(
            reading: FakeBrowserNavigationReading(resolution: .navigated(navigated()))
        )
        #expect(worker.handle(request("browser.navigate", ["url": .string("https://x")])) == .ok(.object([
            "workspace_id": .string(workspaceID.uuidString),
            "workspace_ref": .string("workspace:1"),
            "surface_id": .string(surfaceID.uuidString),
            "surface_ref": .string("surface:1"),
            "window_id": .string(windowID.uuidString),
            "window_ref": .string("window:1"),
        ])))
    }

    @Test func navigatedWithoutWindowEmitsNulls() {
        let worker = ControlBrowserNavigationWorker(
            reading: FakeBrowserNavigationReading(
                resolution: .navigated(navigated(windowID: nil, windowRef: nil))
            )
        )
        #expect(worker.handle(request("browser.reload")) == .ok(.object([
            "workspace_id": .string(workspaceID.uuidString),
            "workspace_ref": .string("workspace:1"),
            "surface_id": .string(surfaceID.uuidString),
            "surface_ref": .string("surface:1"),
            "window_id": .null,
            "window_ref": .null,
        ])))
    }

    @Test func navigatedMergesPostSnapshotKeys() {
        let worker = ControlBrowserNavigationWorker(
            reading: FakeBrowserNavigationReading(
                resolution: .navigated(navigated(postSnapshot: [
                    "post_action_title": .string("Example"),
                    "post_action_url": .string("https://x"),
                ]))
            )
        )
        guard case .ok(.object(let payload))? = worker.handle(
            request("browser.navigate", ["url": .string("https://x")])
        ) else {
            Issue.record("expected ok object")
            return
        }
        #expect(payload["post_action_title"] == .string("Example"))
        #expect(payload["post_action_url"] == .string("https://x"))
        #expect(payload["workspace_id"] == .string(workspaceID.uuidString))
    }
}
