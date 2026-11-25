@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import CmuxNextCompat
import Testing

/// Each `browser.page.*` call tells the engine whether it only reads the page (``BrowserPageIntent``): the app
/// leaves a page's passkeys to the person through an agent's reads and refuses them again at its next action
/// (Google's passkey challenge, 2026-11-20: the Chief's `state` / `snapshot` watch every 5 s refused the request
/// the page started after the person's click, before Chromium's sheet with the phone QR code).
@Suite(.timeLimit(.minutes(1))) struct BrowserPageIntentTests {
    final class IntentEngine: BrowserPageEngine {
        let seen = Mutex<[BrowserPageIntent]>([])

        func run(_ operation: BrowserPageOperation, tabID: String, url: String?) async throws -> JSONValue {
            seen.withLock { $0.append(BrowserPageIntent.current) }
            switch operation {
            case .state: return ["url": "https://accounts.google.com/", "title": "Sign in"]
            case .screenshot: return ["png_base64": "", "width": 1, "height": 1]
            default: return ["value": ["value": true, "ready": true, "snapshot": "", "refs": [:]]]
            }
        }

        func take() -> [BrowserPageIntent] { seen.withLock { value in defer { value = [] }; return value } }
    }

    func install() -> (ControlRouter, IntentEngine) {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        let engine = IntentEngine()
        BrowserPageService(engine: engine).install(on: router)
        var snapshot = ControlSnapshot.sample()
        let tab = ControlTabInfo(id: "tab_0123abcd", surface: "12", kind: "browser", title: "Sign in", url: "https://accounts.google.com/")
        snapshot.topology.workspaces[0].screens[0].panes[0].tabs.append(tab)
        router.snapshots.publish { $0 = snapshot }
        return (router, engine)
    }

    func call(_ router: ControlRouter, _ verb: String, _ params: [String: JSONValue] = [:]) async {
        var params = params
        params["tab"] = "tab_0123abcd"
        params["agent"] = "Chief"
        _ = try? await router.handle(ControlRequest(method: "browser.page." + verb, params: params)).get()
    }

    @Test(arguments: [
        ("state", [:]), ("snapshot", ["interactive": true]), ("text", ["selector": "h1"]), ("value", ["selector": "#id"]),
        ("wait", ["selector": "button", "timeout_ms": 50]),
    ] as [(String, [String: JSONValue])])
    func readsTellTheEngineTheyRead(_ verb: String, _ params: [String: JSONValue]) async {
        let (router, engine) = install()
        await call(router, verb, params)
        let seen = engine.take()
        #expect(!seen.isEmpty, "\(verb) reached the engine")
        #expect(seen.allSatisfy { $0 == .reads }, "\(verb): \(seen)")
    }

    @Test(arguments: [
        ("click", ["selector": "#next"]), ("fill", ["selector": "#id", "text": "a"]), ("eval", ["script": "1"]),
        ("navigate", ["url": "https://accounts.google.com/"]), ("press", ["key": "Enter"]),
        // An agent's own script in a wait can call navigator.credentials.get itself.
        ("wait", ["function": "navigator.credentials", "timeout_ms": 50]),
    ] as [(String, [String: JSONValue])])
    func actionsTellTheEngineTheyAct(_ verb: String, _ params: [String: JSONValue]) async {
        let (router, engine) = install()
        await call(router, verb, params)
        let seen = engine.take()
        #expect(!seen.isEmpty, "\(verb) reached the engine")
        #expect(seen.allSatisfy { $0 == .acts }, "\(verb): \(seen)")
    }
}
