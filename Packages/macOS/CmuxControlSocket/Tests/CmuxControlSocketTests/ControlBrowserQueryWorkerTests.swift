import Foundation
import Testing
@testable import CmuxControlSocket

/// A scriptable ``ControlBrowserQueryReading`` for driving
/// ``ControlBrowserQueryWorker`` without the app target or a live browser
/// surface. Returns a fixed resolution and records the request it was handed.
private final class FakeBrowserQueryReading: ControlBrowserQueryReading, @unchecked Sendable {
    var resolution: ControlBrowserFindResolution
    private(set) var lastRequest: ControlBrowserFindRequest?

    init(resolution: ControlBrowserFindResolution) {
        self.resolution = resolution
    }

    func resolveFind(_ request: ControlBrowserFindRequest) -> ControlBrowserFindResolution {
        lastRequest = request
        return resolution
    }
}

private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
    ControlRequest(id: .string("1"), method: method, params: params)
}

private let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
private let surfaceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

private func foundElement(
    selector: String,
    tag: String?,
    text: ControlBrowserFindResultText,
    index: ControlBrowserFindResultIndex? = nil
) -> ControlBrowserFoundElement {
    ControlBrowserFoundElement(
        workspaceID: workspaceID,
        workspaceRef: "workspace:1",
        surfaceID: surfaceID,
        surfaceRef: "surface:1",
        selector: selector,
        elementRef: "@e1",
        tag: tag,
        text: text,
        index: index
    )
}

@Suite struct ControlBrowserQueryWorkerTests {
    @Test func returnsNilForNonFindMethod() {
        let worker = ControlBrowserQueryWorker(
            reading: FakeBrowserQueryReading(resolution: .notFound(data: nil))
        )
        #expect(worker.handle(request("browser.get.text")) == nil)
        #expect(worker.handle(request("browser.find")) == nil)
    }

    // MARK: - find.role (with-script family)

    @Test func findRoleRequiresRole() {
        let worker = ControlBrowserQueryWorker(
            reading: FakeBrowserQueryReading(resolution: .notFound(data: nil))
        )
        let result = worker.handle(request("browser.find.role"))
        #expect(result == .err(code: "invalid_params", message: "Missing role", data: nil))
    }

    @Test func findRoleLowercasesAndForwardsParsedInputs() {
        let reading = FakeBrowserQueryReading(
            resolution: .found(foundElement(selector: "button", tag: "BUTTON", text: .string("Save")))
        )
        let worker = ControlBrowserQueryWorker(reading: reading)
        _ = worker.handle(request("browser.find.role", [
            "role": .string("BUTTON"),
            "name": .string("Save"),
            "exact": .bool(true),
        ]))
        guard case .role(_, let role, let name, let exact)? = reading.lastRequest else {
            Issue.record("expected .role request")
            return
        }
        #expect(role == "button")
        #expect(name == "save")
        #expect(exact == true)
    }

    @Test func findRoleSuccessShapesPayloadWithMetadataAndEchoes() {
        let reading = FakeBrowserQueryReading(
            resolution: .found(foundElement(selector: "button", tag: "BUTTON", text: .string("Save")))
        )
        let worker = ControlBrowserQueryWorker(reading: reading)
        let result = worker.handle(request("browser.find.role", [
            "role": .string("button"),
            "name": .string("Save"),
        ]))
        #expect(result == .ok(.object([
            "workspace_id": .string(workspaceID.uuidString),
            "workspace_ref": .string("workspace:1"),
            "surface_id": .string(surfaceID.uuidString),
            "surface_ref": .string("surface:1"),
            "action": .string("find.role"),
            "selector": .string("button"),
            "element_ref": .string("@e1"),
            "ref": .string("@e1"),
            "role": .string("button"),
            "name": .string("save"),
            "exact": .bool(false),
            "tag": .string("BUTTON"),
            "text": .string("Save"),
        ])))
    }

    @Test func findRoleNotFoundUsesMetadataAsData() {
        let reading = FakeBrowserQueryReading(resolution: .notFound(data: nil))
        let worker = ControlBrowserQueryWorker(reading: reading)
        let result = worker.handle(request("browser.find.role", ["role": .string("button")]))
        #expect(result == .err(
            code: "not_found",
            message: "Element not found",
            data: .object(["role": .string("button"), "name": .null, "exact": .bool(false)])
        ))
    }

    @Test func findRoleJSErrorCarriesAction() {
        let reading = FakeBrowserQueryReading(resolution: .jsError(message: "boom"))
        let worker = ControlBrowserQueryWorker(reading: reading)
        let result = worker.handle(request("browser.find.role", ["role": .string("button")]))
        #expect(result == .err(code: "js_error", message: "boom", data: .object(["action": .string("find.role")])))
    }

    @Test func findRolePanelUnavailablePassesThrough() {
        let reading = FakeBrowserQueryReading(
            resolution: .panelUnavailable(.err(code: "unavailable", message: "TabManager not available", data: nil))
        )
        let worker = ControlBrowserQueryWorker(reading: reading)
        let result = worker.handle(request("browser.find.role", ["role": .string("button")]))
        #expect(result == .err(code: "unavailable", message: "TabManager not available", data: nil))
    }

    @Test func findRoleOmitsTagAndTextWhenAbsent() {
        let reading = FakeBrowserQueryReading(
            resolution: .found(foundElement(selector: "button", tag: nil, text: .omitted))
        )
        let worker = ControlBrowserQueryWorker(reading: reading)
        guard case .ok(.object(let payload))? = worker.handle(
            request("browser.find.role", ["role": .string("button")])
        ) else {
            Issue.record("expected ok object")
            return
        }
        #expect(payload["tag"] == nil)
        #expect(payload["text"] == nil)
    }

    // MARK: - find.testid does not lowercase

    @Test func findTestIDForwardsRawValue() {
        let reading = FakeBrowserQueryReading(resolution: .notFound(data: nil))
        let worker = ControlBrowserQueryWorker(reading: reading)
        _ = worker.handle(request("browser.find.testid", ["testid": .string("SubmitBTN")]))
        guard case .testID(_, let testID)? = reading.lastRequest else {
            Issue.record("expected .testID request")
            return
        }
        #expect(testID == "SubmitBTN")
    }

    // MARK: - find.first / last / nth (selector family)

    @Test func findFirstRequiresSelector() {
        let worker = ControlBrowserQueryWorker(
            reading: FakeBrowserQueryReading(resolution: .notFound(data: nil))
        )
        #expect(worker.handle(request("browser.find.first")) == .err(
            code: "invalid_params", message: "Missing selector", data: nil
        ))
    }

    @Test func findFirstResolvesSelectorAliases() {
        let reading = FakeBrowserQueryReading(resolution: .notFound(data: nil))
        let worker = ControlBrowserQueryWorker(reading: reading)
        _ = worker.handle(request("browser.find.first", ["ref": .string("@e7")]))
        guard case .first(_, let rawSelector)? = reading.lastRequest else {
            Issue.record("expected .first request")
            return
        }
        #expect(rawSelector == "@e7")
    }

    @Test func findFirstSuccessShapesPayloadWithOrNullText() {
        let reading = FakeBrowserQueryReading(
            resolution: .found(foundElement(selector: ".item", tag: nil, text: .orNull("Hello")))
        )
        let worker = ControlBrowserQueryWorker(reading: reading)
        let result = worker.handle(request("browser.find.first", ["selector": .string(".item")]))
        #expect(result == .ok(.object([
            "workspace_id": .string(workspaceID.uuidString),
            "workspace_ref": .string("workspace:1"),
            "surface_id": .string(surfaceID.uuidString),
            "surface_ref": .string("surface:1"),
            "selector": .string(".item"),
            "element_ref": .string("@e1"),
            "ref": .string("@e1"),
            "text": .string("Hello"),
        ])))
    }

    @Test func findFirstSelectorReferenceNotFound() {
        let reading = FakeBrowserQueryReading(resolution: .selectorReferenceNotFound(rawSelector: "@e9"))
        let worker = ControlBrowserQueryWorker(reading: reading)
        let result = worker.handle(request("browser.find.first", ["selector": .string("@e9")]))
        #expect(result == .err(
            code: "not_found",
            message: "Element reference not found",
            data: .object(["selector": .string("@e9")])
        ))
    }

    @Test func findFirstNotFoundCarriesSeamData() {
        let reading = FakeBrowserQueryReading(resolution: .notFound(data: ["selector": .string(".item")]))
        let worker = ControlBrowserQueryWorker(reading: reading)
        let result = worker.handle(request("browser.find.first", ["selector": .string(".item")]))
        #expect(result == .err(
            code: "not_found",
            message: "Element not found",
            data: .object(["selector": .string(".item")])
        ))
    }

    @Test func findNthRequiresIndex() {
        let worker = ControlBrowserQueryWorker(
            reading: FakeBrowserQueryReading(resolution: .notFound(data: nil))
        )
        #expect(worker.handle(request("browser.find.nth", ["selector": .string(".item")])) == .err(
            code: "invalid_params", message: "Missing index", data: nil
        ))
    }

    @Test func findNthAcceptsIndexAndNthKeysAndForwards() {
        let reading = FakeBrowserQueryReading(resolution: .notFound(data: nil))
        let worker = ControlBrowserQueryWorker(reading: reading)
        _ = worker.handle(request("browser.find.nth", ["selector": .string(".item"), "nth": .int(3)]))
        guard case .nth(_, let rawSelector, let index)? = reading.lastRequest else {
            Issue.record("expected .nth request")
            return
        }
        #expect(rawSelector == ".item")
        #expect(index == 3)
    }

    @Test func findNthSuccessIncludesIndexAndText() {
        let reading = FakeBrowserQueryReading(
            resolution: .found(foundElement(
                selector: ".item:nth-of-type(3)",
                tag: nil,
                text: .orNull("Row"),
                index: .orNull(2)
            ))
        )
        let worker = ControlBrowserQueryWorker(reading: reading)
        let result = worker.handle(request("browser.find.nth", [
            "selector": .string(".item"),
            "index": .int(2),
        ]))
        #expect(result == .ok(.object([
            "workspace_id": .string(workspaceID.uuidString),
            "workspace_ref": .string("workspace:1"),
            "surface_id": .string(surfaceID.uuidString),
            "surface_ref": .string("surface:1"),
            "selector": .string(".item:nth-of-type(3)"),
            "element_ref": .string("@e1"),
            "ref": .string("@e1"),
            "index": .int(2),
            "text": .string("Row"),
        ])))
    }

    @Test func findNthNotFoundCarriesSelectorAndIndexData() {
        let reading = FakeBrowserQueryReading(
            resolution: .notFound(data: ["selector": .string(".item"), "index": .int(99)])
        )
        let worker = ControlBrowserQueryWorker(reading: reading)
        let result = worker.handle(request("browser.find.nth", [
            "selector": .string(".item"),
            "index": .int(99),
        ]))
        #expect(result == .err(
            code: "not_found",
            message: "Element not found",
            data: .object(["selector": .string(".item"), "index": .int(99)])
        ))
    }
}
