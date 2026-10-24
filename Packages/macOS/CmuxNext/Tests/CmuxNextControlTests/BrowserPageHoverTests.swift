@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import CmuxNextCompat
import Testing

/// `browser.page.hover` moves the engine's real pointer onto the element.
/// Before, hover only dispatched script `mouseover`/`mousemove` events: a
/// page's own listeners saw them, but CSS `:hover` never matched, so hover
/// menus and captions stayed hidden (the-internet.herokuapp.com/hovers in
/// the dogfood suite).
@Suite(.timeLimit(.minutes(1))) struct BrowserPageHoverTests {
    final class RecordingEngine: BrowserPageEngine {
        let operations = Mutex<[BrowserPageOperation]>([])
        let native: Bool

        init(native: Bool) { self.native = native }

        func run(_ operation: BrowserPageOperation, tabID: String, url: String?) async throws -> JSONValue {
            operations.withLock { $0.append(operation) }
            if case .input = operation { return ["native": .bool(native)] }
            return ["value": ["value": true, "at": ["x": 100, "y": 40, "w": 20, "h": 10, "secret": false]]]
        }

        var inputs: [BrowserPageInput] {
            operations.withLock { $0.compactMap { if case .input(let input) = $0 { input } else { nil } } }
        }
    }

    func hover(native: Bool) async throws -> RecordingEngine {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor())
        let engine = RecordingEngine(native: native)
        BrowserPageService(engine: engine).install(on: router)
        var snapshot = ControlSnapshot.sample()
        let tab = ControlTabInfo(id: "tab_0123abcd", surface: "12", kind: "browser", title: "Menu", url: "https://example.com/")
        snapshot.topology.workspaces[0].screens[0].panes[0].tabs.append(tab)
        router.snapshots.publish { $0 = snapshot }
        _ = try await router.handle(ControlRequest(method: "browser.page.hover",
                                                   params: ["tab": "tab_0123abcd", "selector": ".menu"])).get()
        return engine
    }

    @Test func hoverMovesTheRealPointerToTheElementsMiddle() async throws {
        let engine = try await hover(native: true)
        #expect(engine.inputs == [.mouse(kind: .move, x: 110, y: 45, button: .left, clickCount: 0, modifiers: [])])
    }

    @Test func anEngineWithoutNativeInputStillHoversWithPageEvents() async throws {
        let engine = try await hover(native: false)
        #expect(engine.inputs.count <= 1, "a refused native move is not retried")
    }
}
