import Foundation
import Testing
@testable import CmuxControlSocket

/// A scriptable ``ControlCommandContext`` returning canned resolutions for the
/// browser addscript/addstyle/addinitscript/dialog/import witnesses, so the
/// coordinator's param validation and `JSONValue` payload shaping can be tested
/// without the live app. The fake records the args it received so the
/// coordinator-owned param parsing (script/css/text fallbacks, accept intent)
/// can be asserted at the seam boundary.
@MainActor
private final class FakeBrowserScriptDialogContext: ControlCommandContext {
    var addInitScript: ControlBrowserAddInitScriptResolution = .failed(.tabManagerUnavailable)
    var addScript: ControlBrowserAddScriptResolution = .failed(.tabManagerUnavailable)
    var addStyle: ControlBrowserAddStyleResolution = .failed(.tabManagerUnavailable)
    var dialog: ControlBrowserDialogRespondResolution = .failed(.tabManagerUnavailable)
    var importDialog: ControlBrowserImportDialogResolution = .opened(scopeRawValue: nil)

    private(set) var lastScript: String?
    private(set) var lastCSS: String?
    private(set) var lastDialogAccept: Bool?
    private(set) var lastDialogText: String?

    func controlBrowserAddInitScript(
        params: [String: JSONValue],
        script: String
    ) -> ControlBrowserAddInitScriptResolution {
        lastScript = script
        return addInitScript
    }

    func controlBrowserAddScript(
        params: [String: JSONValue],
        script: String
    ) -> ControlBrowserAddScriptResolution {
        lastScript = script
        return addScript
    }

    func controlBrowserAddStyle(
        params: [String: JSONValue],
        css: String
    ) -> ControlBrowserAddStyleResolution {
        lastCSS = css
        return addStyle
    }

    func controlBrowserDialogRespond(
        params: [String: JSONValue],
        accept: Bool,
        text: String?
    ) -> ControlBrowserDialogRespondResolution {
        lastDialogAccept = accept
        lastDialogText = text
        return dialog
    }

    func controlBrowserImportDialog(
        params: [String: JSONValue]
    ) -> ControlBrowserImportDialogResolution {
        importDialog
    }
}

@MainActor
@Suite("ControlCommandCoordinator browser script/dialog domain")
struct ControlCommandCoordinatorBrowserScriptDialogTests {
    private func makeCoordinator() -> (ControlCommandCoordinator, FakeBrowserScriptDialogContext) {
        let context = FakeBrowserScriptDialogContext()
        return (ControlCommandCoordinator(context: context), context)
    }

    private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }

    // MARK: - addinitscript

    @Test func addInitScriptMissingScriptIsInvalidParams() {
        let (coordinator, _) = makeCoordinator()
        guard case .err(let code, let message, let data)? = coordinator.handle(request("browser.addinitscript")) else {
            Issue.record("expected error"); return
        }
        #expect(code == "invalid_params")
        #expect(message == "Missing script")
        #expect(data == nil)
    }

    @Test func addInitScriptFallsBackToContentParam() {
        let (coordinator, context) = makeCoordinator()
        _ = coordinator.handle(request("browser.addinitscript", ["content": .string("doThing()")]))
        #expect(context.lastScript == "doThing()")
    }

    @Test func addInitScriptResolvedShapesScriptsCount() {
        let (coordinator, context) = makeCoordinator()
        let ws = UUID(); let surface = UUID()
        context.addInitScript = .resolved(workspaceID: ws, surfaceID: surface, scriptCount: 3)
        guard case .ok(let value)? = coordinator.handle(
            request("browser.addinitscript", ["script": .string("x")])
        ) else { Issue.record("expected ok"); return }
        #expect(value == .object([
            "workspace_id": .string(ws.uuidString),
            "workspace_ref": coordinator.ref(.workspace, ws),
            "surface_id": .string(surface.uuidString),
            "surface_ref": coordinator.ref(.surface, surface),
            "scripts": .int(3),
        ]))
    }

    @Test func addInitScriptPanelFailureMapsToLegacyError() {
        let (coordinator, context) = makeCoordinator()
        context.addInitScript = .failed(.noFocusedBrowserSurface)
        guard case .err(let code, let message, _)? = coordinator.handle(
            request("browser.addinitscript", ["script": .string("x")])
        ) else { Issue.record("expected error"); return }
        #expect(code == "not_found")
        #expect(message == "No focused browser surface")
    }

    // MARK: - addscript

    @Test func addScriptMissingScriptIsInvalidParams() {
        let (coordinator, _) = makeCoordinator()
        guard case .err(let code, let message, _)? = coordinator.handle(request("browser.addscript")) else {
            Issue.record("expected error"); return
        }
        #expect(code == "invalid_params")
        #expect(message == "Missing script")
    }

    @Test func addScriptResolvedEchoesValue() {
        let (coordinator, context) = makeCoordinator()
        let ws = UUID(); let surface = UUID()
        context.addScript = .resolved(workspaceID: ws, surfaceID: surface, value: .int(42))
        guard case .ok(let value)? = coordinator.handle(
            request("browser.addscript", ["script": .string("21*2")])
        ) else { Issue.record("expected ok"); return }
        #expect(value == .object([
            "workspace_id": .string(ws.uuidString),
            "workspace_ref": coordinator.ref(.workspace, ws),
            "surface_id": .string(surface.uuidString),
            "surface_ref": coordinator.ref(.surface, surface),
            "value": .int(42),
        ]))
    }

    @Test func addScriptJSErrorMapsToJsErrorCode() {
        let (coordinator, context) = makeCoordinator()
        context.addScript = .jsError(message: "boom")
        guard case .err(let code, let message, let data)? = coordinator.handle(
            request("browser.addscript", ["script": .string("x")])
        ) else { Issue.record("expected error"); return }
        #expect(code == "js_error")
        #expect(message == "boom")
        #expect(data == nil)
    }

    // MARK: - addstyle

    @Test func addStyleMissingContentIsInvalidParams() {
        let (coordinator, _) = makeCoordinator()
        guard case .err(let code, let message, _)? = coordinator.handle(request("browser.addstyle")) else {
            Issue.record("expected error"); return
        }
        #expect(code == "invalid_params")
        #expect(message == "Missing css/style content")
    }

    @Test func addStyleAcceptsCSSStyleAndContentAliases() {
        let (coordinator, context) = makeCoordinator()
        _ = coordinator.handle(request("browser.addstyle", ["style": .string("body{}")]))
        #expect(context.lastCSS == "body{}")
        _ = coordinator.handle(request("browser.addstyle", ["content": .string("a{}")]))
        #expect(context.lastCSS == "a{}")
        // css wins over style/content (first in the legacy ?? chain).
        _ = coordinator.handle(request("browser.addstyle", [
            "css": .string("c{}"), "style": .string("s{}"), "content": .string("k{}"),
        ]))
        #expect(context.lastCSS == "c{}")
    }

    @Test func addStyleResolvedShapesStylesCount() {
        let (coordinator, context) = makeCoordinator()
        let ws = UUID(); let surface = UUID()
        context.addStyle = .resolved(workspaceID: ws, surfaceID: surface, styleCount: 2)
        guard case .ok(let value)? = coordinator.handle(
            request("browser.addstyle", ["css": .string("body{}")])
        ) else { Issue.record("expected ok"); return }
        #expect(value == .object([
            "workspace_id": .string(ws.uuidString),
            "workspace_ref": coordinator.ref(.workspace, ws),
            "surface_id": .string(surface.uuidString),
            "surface_ref": coordinator.ref(.surface, surface),
            "styles": .int(2),
        ]))
    }

    // MARK: - dialog.accept / dialog.dismiss

    @Test func dialogAcceptPassesAcceptTrueAndTextFallback() {
        let (coordinator, context) = makeCoordinator()
        _ = coordinator.handle(request("browser.dialog.accept", ["prompt_text": .string("hi")]))
        #expect(context.lastDialogAccept == true)
        #expect(context.lastDialogText == "hi")

        _ = coordinator.handle(request("browser.dialog.dismiss", ["text": .string("bye"), "prompt_text": .string("ignored")]))
        #expect(context.lastDialogAccept == false)
        // `text` wins over `prompt_text`.
        #expect(context.lastDialogText == "bye")
    }

    @Test func dialogResolvedShapesPayloadWithAcceptedAndRemaining() {
        let (coordinator, context) = makeCoordinator()
        let ws = UUID(); let surface = UUID()
        let dialogEntry: JSONValue = .object(["type": .string("confirm"), "message": .string("ok?")])
        context.dialog = .resolved(workspaceID: ws, surfaceID: surface, dialog: dialogEntry, remaining: .int(1))
        guard case .ok(let value)? = coordinator.handle(request("browser.dialog.accept")) else {
            Issue.record("expected ok"); return
        }
        #expect(value == .object([
            "workspace_id": .string(ws.uuidString),
            "workspace_ref": coordinator.ref(.workspace, ws),
            "surface_id": .string(surface.uuidString),
            "surface_ref": coordinator.ref(.surface, surface),
            "accepted": .bool(true),
            "dialog": dialogEntry,
            "remaining": .int(1),
        ]))
    }

    @Test func dialogNotFoundCarriesPendingSnapshot() {
        let (coordinator, context) = makeCoordinator()
        let pending: [JSONValue] = [.object(["index": .int(0), "type": .string("alert")])]
        context.dialog = .notFound(pending: pending)
        guard case .err(let code, let message, let data)? = coordinator.handle(request("browser.dialog.dismiss")) else {
            Issue.record("expected error"); return
        }
        #expect(code == "not_found")
        #expect(message == "No pending dialog")
        #expect(data == .object(["pending": .array(pending)]))
    }

    @Test func dialogJSErrorMapsToJsErrorCode() {
        let (coordinator, context) = makeCoordinator()
        context.dialog = .jsError(message: "eval failed")
        guard case .err(let code, let message, _)? = coordinator.handle(request("browser.dialog.accept")) else {
            Issue.record("expected error"); return
        }
        #expect(code == "js_error")
        #expect(message == "eval failed")
    }

    // MARK: - import.dialog

    @Test func importDialogOpenedShapesScopeKey() {
        let (coordinator, context) = makeCoordinator()
        context.importDialog = .opened(scopeRawValue: "cookiesOnly")
        guard case .ok(let value)? = coordinator.handle(request("browser.import.dialog")) else {
            Issue.record("expected ok"); return
        }
        #expect(value == .object(["opened": .bool(true), "scope": .string("cookiesOnly")]))
    }

    @Test func importDialogOpenedNilScopeIsNull() {
        let (coordinator, context) = makeCoordinator()
        context.importDialog = .opened(scopeRawValue: nil)
        guard case .ok(let value)? = coordinator.handle(request("browser.import.dialog")) else {
            Issue.record("expected ok"); return
        }
        #expect(value == .object(["opened": .bool(true), "scope": .null]))
    }

    @Test func importDialogFailureCategoriesMapToLegacyErrors() {
        let cases: [(ControlBrowserImportDialogResolution, String, String)] = [
            (.scopeEmpty, "scope", "scope must be a non-empty string"),
            (.scopeInvalid, "scope", "scope is invalid"),
            (.destinationProfileEmpty, "destination_profile", "destination_profile must be a non-empty string"),
            (.destinationProfileNoMatch, "destination_profile", "destination_profile does not match a cmux browser profile"),
            (.destinationProfileCreateFailed, "destination_profile", "destination_profile could not be created"),
        ]
        for (resolution, param, expectedMessage) in cases {
            let (coordinator, context) = makeCoordinator()
            context.importDialog = resolution
            guard case .err(let code, let message, let data)? = coordinator.handle(request("browser.import.dialog")) else {
                Issue.record("expected error for \(resolution)"); continue
            }
            #expect(code == "invalid_params")
            #expect(message == expectedMessage)
            #expect(data == .object(["param": .string(param)]))
        }
    }
}
