import CmuxBrowser
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("Control socket browser engine selection")
struct ControlCommandCoordinatorBrowserEngineTests {
    @Test("pane.create propagates an explicit Chromium engine")
    func paneCreateChromium() {
        let context = FakeSurfaceControlCommandContext()
        context.paneCreateResolution = .createFailed
        let coordinator = ControlCommandCoordinator(context: context)

        _ = coordinator.handle(request(
            method: "pane.create",
            params: [
                "direction": .string("right"),
                "type": .string("browser"),
                "engine": .string("chromium"),
            ]
        ))

        #expect(context.paneCreateInputs?.typeRaw == "browser")
        #expect(context.paneCreateInputs?.engine == .chromium)
    }

    @Test("surface.create propagates an explicit Chromium engine")
    func surfaceCreateChromium() {
        let context = FakeSurfaceControlCommandContext()
        context.createResolution = .createFailed
        let coordinator = ControlCommandCoordinator(context: context)

        _ = coordinator.handle(request(
            method: "surface.create",
            params: [
                "type": .string("browser"),
                "engine": .string("chromium"),
            ]
        ))

        #expect(context.surfaceCreateInputs?.typeRaw == "browser")
        #expect(context.surfaceCreateInputs?.engine == .chromium)
    }

    @Test("omitting engine preserves settings inheritance")
    func omittedEngine() {
        let context = FakeSurfaceControlCommandContext()
        context.paneCreateResolution = .createFailed
        let coordinator = ControlCommandCoordinator(context: context)

        _ = coordinator.handle(request(
            method: "pane.create",
            params: [
                "direction": .string("right"),
                "type": .string("browser"),
            ]
        ))

        #expect(context.paneCreateInputs?.engine == nil)
    }

    @Test("invalid engine values are rejected before creation")
    func invalidEngine() {
        let context = FakeSurfaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(request(
            method: "pane.create",
            params: [
                "direction": .string("right"),
                "type": .string("browser"),
                "engine": .string("blink"),
            ]
        ))

        #expect(result == .err(
            code: "invalid_params",
            message: BrowserEngineKind.invalidOptionMessage,
            data: .object(["engine": .string("blink")])
        ))
        #expect(context.paneCreateInputs == nil)
    }

    @Test("engine is rejected for non-browser panes and surfaces")
    func engineRequiresBrowserType() {
        let context = FakeSurfaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let expected = ControlCallResult.err(
            code: "invalid_params",
            message: BrowserEngineKind.browserOnlyOptionMessage,
            data: .object(["type": .string("terminal")])
        )

        let paneResult = coordinator.handle(request(
            method: "pane.create",
            params: [
                "direction": .string("right"),
                "type": .string("terminal"),
                "engine": .string("chromium"),
            ]
        ))
        let surfaceResult = coordinator.handle(request(
            method: "surface.create",
            params: [
                "type": .string("terminal"),
                "engine": .string("chromium"),
            ]
        ))

        #expect(paneResult == expected)
        #expect(surfaceResult == expected)
        #expect(context.paneCreateInputs == nil)
        #expect(context.surfaceCreateInputs == nil)
    }

    private func request(
        method: String,
        params: [String: JSONValue]
    ) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }
}
