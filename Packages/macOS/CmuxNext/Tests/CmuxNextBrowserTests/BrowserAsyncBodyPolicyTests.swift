import AppKit
@testable import CmuxNextBrowser
import Foundation
import JavaScriptCore
import Observation
import Testing

/// Exercises the protocol's async wrapper used by CEF, with a real JavaScript parser.
@MainActor @Suite struct BrowserAsyncBodyPolicyTests {
    @Test func sourceCannotEscapeTheDefaultAsyncWrapper() async throws {
        let tab = try Tab()
        let body = """
        if (this.location.origin !== 'https://admitted.test') throw 'navigated';
        }); this.executed = true; (async () => {
        """
        _ = try? await tab.evaluateAsync(body)
        #expect(tab.context.objectForKeyedSubscript("executed")?.toBool() == false)
        #expect(tab.evaluations == 0, "a malformed body must not reach the page")
    }

    @Test func aValidAsyncBodyReachesThePageWithoutDynamicEval() async throws {
        let tab = try Tab()
        _ = try await tab.evaluateAsync("this.executed = true; return 42;")
        #expect(tab.context.objectForKeyedSubscript("executed")?.toBool() == true)
        #expect(tab.evaluations == 1)
    }

    @Observable final class Tab: BrowserTab {
        let id = BrowserTabID(rawValue: "async-body-test")
        let engineKind = BrowserEngineKind.cef
        let profileID = BrowserProfileID(rawValue: UUID())
        let presentation = BrowserPresentation.childWindow
        let contentView = NSView()
        let state = BrowserTabStateMachine().state
        let favicon: NSImage? = nil
        let pendingPrompts: [BrowserPrompt] = []
        weak var delegate: (any BrowserTabDelegate)?
        weak var keyRouter: (any BrowserKeyRouting)?
        let context: JSContext
        var evaluations = 0

        init() throws {
            context = try #require(JSContext())
            context.evaluateScript("this.location = { origin: 'https://filled.test' }; this.executed = false; this.eval = () => { throw 'CSP'; };")
        }

        func evaluate(_ script: String, world: BrowserScriptWorld, gesture: BrowserScriptGesture) async throws -> BrowserJSValue {
            evaluations += 1
            context.exception = nil
            context.evaluateScript(script)
            if let exception = context.exception { throw BrowserTabError.javaScript(exception.toString()) }
            return .null
        }

        func load(_ url: URL) {}
        func goBack() {}
        func goForward() {}
        func reload() {}
        func stop() {}
        func setFocused(_ focused: Bool) {}
        func setContentVisible(_ visible: Bool) {}
        func snapshot() async throws -> CGImage { throw BrowserTabError.snapshotUnavailable }
        func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult { .none }
        func clearFind() {}
        func setZoom(_ zoom: Double) {}
        func exitContentFullscreen() {}
        func showDevTools() {}
        func close() {}
    }
}
