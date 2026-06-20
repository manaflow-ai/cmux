import Foundation
import Testing
@testable import CmuxControlSocket

/// A scriptable ``ControlBrowserInteractionReading`` for driving
/// ``ControlBrowserInteractionWorker`` without the app target or a live browser
/// surface. Returns a fixed resolution and records the request it was handed.
private final class FakeBrowserInteractionReading: ControlBrowserInteractionReading, @unchecked Sendable {
    var resolution: ControlBrowserInteractionResolution
    private(set) var lastRequest: ControlBrowserInteractionRequest?

    init(resolution: ControlBrowserInteractionResolution) {
        self.resolution = resolution
    }

    func resolveInteraction(_ request: ControlBrowserInteractionRequest) -> ControlBrowserInteractionResolution {
        lastRequest = request
        return resolution
    }
}

private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
    ControlRequest(id: .string("1"), method: method, params: params)
}

private let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
private let surfaceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

private func panelSuccess(postSnapshot: [String: JSONValue] = [:]) -> ControlBrowserInteractionResolution {
    .panelAction(ControlBrowserPanelActionSuccess(
        workspaceID: workspaceID,
        workspaceRef: "workspace:1",
        surfaceID: surfaceID,
        surfaceRef: "surface:1",
        postSnapshot: postSnapshot
    ))
}

@Suite struct ControlBrowserInteractionWorkerTests {
    @Test func returnsNilForNonInteractionMethod() {
        let worker = ControlBrowserInteractionWorker(
            reading: FakeBrowserInteractionReading(resolution: panelSuccess())
        )
        #expect(worker.handle(request("browser.get.text")) == nil)
        #expect(worker.handle(request("browser.snapshot")) == nil)
        #expect(worker.handle(request("browser.navigate")) == nil)
    }

    // MARK: - Selector-action dispatch (preShaped passthrough)

    @Test func clickForwardsClickRequestAndReturnsPreShaped() {
        let preShaped = ControlCallResult.ok(.object(["action": .string("click")]))
        let reading = FakeBrowserInteractionReading(resolution: .preShaped(preShaped))
        let worker = ControlBrowserInteractionWorker(reading: reading)
        let result = worker.handle(request("browser.click", ["selector": .string("#go")]))
        guard case .click? = reading.lastRequest else {
            Issue.record("expected .click request")
            return
        }
        #expect(result == preShaped)
    }

    @Test func uncheckForwardsCheckedFalse() {
        let reading = FakeBrowserInteractionReading(resolution: .preShaped(.ok(.object([:]))))
        let worker = ControlBrowserInteractionWorker(reading: reading)
        _ = worker.handle(request("browser.uncheck", ["selector": .string("#c")]))
        guard case .check(_, let checked)? = reading.lastRequest else {
            Issue.record("expected .check request")
            return
        }
        #expect(checked == false)
    }

    @Test func checkForwardsCheckedTrue() {
        let reading = FakeBrowserInteractionReading(resolution: .preShaped(.ok(.object([:]))))
        let worker = ControlBrowserInteractionWorker(reading: reading)
        _ = worker.handle(request("browser.check", ["selector": .string("#c")]))
        guard case .check(_, let checked)? = reading.lastRequest else {
            Issue.record("expected .check request")
            return
        }
        #expect(checked == true)
    }

    // MARK: - Leaf-param validation

    @Test func typeRequiresText() {
        let worker = ControlBrowserInteractionWorker(
            reading: FakeBrowserInteractionReading(resolution: .preShaped(.ok(.object([:]))))
        )
        let result = worker.handle(request("browser.type", ["selector": .string("#i")]))
        #expect(result == .err(code: "invalid_params", message: "Missing text", data: nil))
    }

    @Test func typeRejectsWhitespaceOnlyText() {
        let worker = ControlBrowserInteractionWorker(
            reading: FakeBrowserInteractionReading(resolution: .preShaped(.ok(.object([:]))))
        )
        let result = worker.handle(request("browser.type", ["text": .string("   ")]))
        #expect(result == .err(code: "invalid_params", message: "Missing text", data: nil))
    }

    @Test func typeTrimsAndForwardsText() {
        let reading = FakeBrowserInteractionReading(resolution: .preShaped(.ok(.object([:]))))
        let worker = ControlBrowserInteractionWorker(reading: reading)
        _ = worker.handle(request("browser.type", ["text": .string("  hi  ")]))
        guard case .type(_, let text)? = reading.lastRequest else {
            Issue.record("expected .type request")
            return
        }
        #expect(text == "hi")
    }

    @Test func fillRequiresTextOrValue() {
        let worker = ControlBrowserInteractionWorker(
            reading: FakeBrowserInteractionReading(resolution: .preShaped(.ok(.object([:]))))
        )
        let result = worker.handle(request("browser.fill", ["selector": .string("#i")]))
        #expect(result == .err(code: "invalid_params", message: "Missing text/value", data: nil))
    }

    @Test func fillAllowsEmptyStringToClearInput() {
        let reading = FakeBrowserInteractionReading(resolution: .preShaped(.ok(.object([:]))))
        let worker = ControlBrowserInteractionWorker(reading: reading)
        let result = worker.handle(request("browser.fill", ["text": .string("")]))
        guard case .fill(_, let text)? = reading.lastRequest else {
            Issue.record("expected .fill request")
            return
        }
        #expect(text == "")
        #expect(result != .err(code: "invalid_params", message: "Missing text/value", data: nil))
    }

    @Test func fillPrefersTextThenValueRaw() {
        let reading = FakeBrowserInteractionReading(resolution: .preShaped(.ok(.object([:]))))
        let worker = ControlBrowserInteractionWorker(reading: reading)
        _ = worker.handle(request("browser.fill", ["value": .string("  spaced  ")]))
        guard case .fill(_, let text)? = reading.lastRequest else {
            Issue.record("expected .fill request")
            return
        }
        // v2RawString is NOT trimmed.
        #expect(text == "  spaced  ")
    }

    @Test func selectRequiresValueOrText() {
        let worker = ControlBrowserInteractionWorker(
            reading: FakeBrowserInteractionReading(resolution: .preShaped(.ok(.object([:]))))
        )
        let result = worker.handle(request("browser.select", ["selector": .string("#s")]))
        #expect(result == .err(code: "invalid_params", message: "Missing value", data: nil))
    }

    @Test func selectFallsBackToText() {
        let reading = FakeBrowserInteractionReading(resolution: .preShaped(.ok(.object([:]))))
        let worker = ControlBrowserInteractionWorker(reading: reading)
        _ = worker.handle(request("browser.select", ["text": .string("Option A")]))
        guard case .selectOption(_, let value)? = reading.lastRequest else {
            Issue.record("expected .selectOption request")
            return
        }
        #expect(value == "Option A")
    }

    @Test func pressRequiresKey() {
        let worker = ControlBrowserInteractionWorker(
            reading: FakeBrowserInteractionReading(resolution: panelSuccess())
        )
        for method in ["browser.press", "browser.keydown", "browser.keyup"] {
            let result = worker.handle(request(method))
            #expect(result == .err(code: "invalid_params", message: "Missing key", data: nil))
        }
    }

    @Test func keyEventsForwardParsedKey() {
        let reading = FakeBrowserInteractionReading(resolution: panelSuccess())
        let worker = ControlBrowserInteractionWorker(reading: reading)
        _ = worker.handle(request("browser.keydown", ["key": .string("Enter")]))
        guard case .keyDown(_, let key)? = reading.lastRequest else {
            Issue.record("expected .keyDown request")
            return
        }
        #expect(key == "Enter")
    }

    // MARK: - scroll dx/dy defaults

    @Test func scrollDefaultsDeltasToZero() {
        let reading = FakeBrowserInteractionReading(resolution: panelSuccess())
        let worker = ControlBrowserInteractionWorker(reading: reading)
        _ = worker.handle(request("browser.scroll"))
        guard case .scroll(_, let dx, let dy)? = reading.lastRequest else {
            Issue.record("expected .scroll request")
            return
        }
        #expect(dx == 0)
        #expect(dy == 0)
    }

    @Test func scrollParsesDeltas() {
        let reading = FakeBrowserInteractionReading(resolution: panelSuccess())
        let worker = ControlBrowserInteractionWorker(reading: reading)
        _ = worker.handle(request("browser.scroll", ["dx": .int(40), "dy": .double(120.9)]))
        guard case .scroll(_, let dx, let dy)? = reading.lastRequest else {
            Issue.record("expected .scroll request")
            return
        }
        #expect(dx == 40)
        // NSNumber.intValue truncates toward zero like the legacy as? NSNumber path.
        #expect(dy == 120)
    }

    // MARK: - panelAction payload shaping

    @Test func panelActionShapesIdentityPayload() {
        let worker = ControlBrowserInteractionWorker(
            reading: FakeBrowserInteractionReading(resolution: panelSuccess())
        )
        let result = worker.handle(request("browser.press", ["key": .string("Tab")]))
        #expect(result == .ok(.object([
            "workspace_id": .string(workspaceID.uuidString),
            "workspace_ref": .string("workspace:1"),
            "surface_id": .string(surfaceID.uuidString),
            "surface_ref": .string("surface:1"),
        ])))
    }

    @Test func panelActionMergesPostSnapshot() {
        let worker = ControlBrowserInteractionWorker(
            reading: FakeBrowserInteractionReading(resolution: panelSuccess(postSnapshot: [
                "post_action_url": .string("https://example.com"),
            ]))
        )
        let result = worker.handle(request("browser.scroll", ["dy": .int(50)]))
        #expect(result == .ok(.object([
            "workspace_id": .string(workspaceID.uuidString),
            "workspace_ref": .string("workspace:1"),
            "surface_id": .string(surfaceID.uuidString),
            "surface_ref": .string("surface:1"),
            "post_action_url": .string("https://example.com"),
        ])))
    }
}
