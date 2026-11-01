@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import CmuxNextCompat
import Testing

/// Browser use thread (user, 2026-10-19): an agent names itself
/// (`params.agent`, `cmux browser … --agent NAME`) so its cursor shows its
/// name; `drag` and `upload` exist and draw; a page scroll draws too.
@Suite(.timeLimit(.minutes(1))) struct BrowserPageBrowserUseTests {
    final class RecordingEngine: BrowserPageEngine {
        let announced = Mutex<[BrowserPageAgentInput]>([])
        let scripts = Mutex<[String]>([])
        let answer: JSONValue

        init(_ answer: JSONValue) { self.answer = answer }

        func run(_ operation: BrowserPageOperation, tabID: String, url: String?) async throws -> JSONValue {
            if case let .evaluate(script) = operation { scripts.withLock { $0.append(script) } }
            return ["value": answer]
        }

        func announce(_ input: BrowserPageAgentInput, tabID: String) async {
            announced.withLock { $0.append(input) }
        }

        var inputs: [BrowserPageAgentInput] { announced.withLock { $0 } }
        var evaluated: [String] { scripts.withLock { $0 } }
    }

    static let at: JSONValue = ["x": 10, "y": 20, "w": 200, "h": 30, "secret": false]

    func install(_ answer: JSONValue) -> (ControlRouter, RecordingEngine) {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        let engine = RecordingEngine(answer)
        BrowserPageService(engine: engine).install(on: router)
        var snapshot = ControlSnapshot.sample()
        let tab = ControlTabInfo(id: "tab_0123abcd", surface: "12", kind: "browser", title: "Form", url: "https://example.com/")
        snapshot.topology.workspaces[0].screens[0].panes[0].tabs.append(tab)
        router.snapshots.publish { $0 = snapshot }
        return (router, engine)
    }

    func call(_ router: ControlRouter, _ verb: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        var params = params
        params["tab"] = "tab_0123abcd"
        return try await router.handle(ControlRequest(method: "browser.page." + verb, params: params)).get()
    }

    @Test func theAgentNameReachesEveryAnnouncedInput() async throws {
        let (router, engine) = install(["value": true, "at": Self.at])
        _ = try await call(router, "click", ["selector": "#go", "agent": "Claude"])
        _ = try await call(router, "hover", ["selector": "#go", "agent": "Claude"])
        _ = try await call(router, "type", ["selector": "#q", "text": "x"])
        #expect(engine.inputs.map(\.agent) == ["Claude", "Claude", nil])
    }

    @Test func aDragAnnouncesTheGrabAndTheDrop() async throws {
        let (router, engine) = install(["value": true, "at": Self.at, "to": ["x": 300, "y": 400, "w": 50, "h": 60, "secret": false]])
        _ = try await call(router, "drag", ["selector": "#card", "target": "#done"])
        let input = try #require(engine.inputs.first)
        #expect(input.kind == .drag)
        #expect(input.rect == .init(x: 10, y: 20, width: 200, height: 30))
        #expect(input.toRect == .init(x: 300, y: 400, width: 50, height: 60))
        await #expect(throws: ControlError.self) { _ = try await call(router, "drag", ["selector": "#card"]) }
    }

    @Test func aPageScrollWithNoSelectorStillDraws() async throws {
        let (router, engine) = install(["value": ["x": 0, "y": 400], "at": ["x": 400, "y": 300, "w": 0, "h": 0, "secret": false]])
        _ = try await call(router, "scroll", ["dy": 400])
        #expect(engine.inputs.map(\.kind) == [.scroll])
    }

    @Test func uploadSendsTheFileBytesAndDrawsAClickOnTheInput() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bu-upload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("note.txt")
        try Data("hello upload".utf8).write(to: file)
        let (router, engine) = install(["value": ["files": ["note.txt"]], "at": Self.at])
        _ = try await call(router, "upload", ["selector": "#file", "files": [.string(file.path)]])
        let script = try #require(engine.evaluated.first(where: { $0.contains(Data("hello upload".utf8).base64EncodedString()) }))
        #expect(script.contains(Data("hello upload".utf8).base64EncodedString()), "the bytes go to the page")
        #expect(engine.evaluated.first?.contains("note.txt") == true)
        #expect(engine.inputs.map(\.kind) == [.click])
        await #expect(throws: ControlError.self) {
            _ = try await call(router, "upload", ["selector": "#file", "files": [.string(dir.appendingPathComponent("missing").path)]])
        }
        await #expect(throws: ControlError.self) { _ = try await call(router, "upload", ["selector": "#file", "files": []]) }
    }
}
