import CmuxNextDaemon
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

@Suite struct CompatServiceTests {
    func makeRouter() -> (ControlRouter, CompatService) {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor())
        let service = CompatService(frontend: HeadlessCompatFrontend()) { nil }
        service.install(on: router)
        return (router, service)
    }

    @Test func unsupportedMethodsAnswerTypedErrors() async {
        let (router, _) = makeRouter()
        guard case .failure(let error) = await router.handle(ControlRequest(method: "canvas.tidy")) else {
            Issue.record("expected failure")
            return
        }
        #expect(error.code == "unsupported")
        #expect(error.message.hasPrefix("unsupported in cmux-next: "))
        guard case .failure(let specific) = await router.handle(ControlRequest(method: "surface.trigger_flash")) else { return }
        #expect(specific.message.contains("flash"))
        guard case .failure(let unknown) = await router.handle(ControlRequest(method: "nonsense.method")) else { return }
        #expect(unknown.code == "method_not_found")
    }

    @Test func daemonMethodsFailFastWithoutAConnection() async {
        let (router, _) = makeRouter()
        let started = ContinuousClock.now
        guard case .failure(let error) = await router.handle(ControlRequest(method: "workspace.list")) else {
            Issue.record("expected failure")
            return
        }
        // The snapshot has not loaded yet: reads fail fast instead of waiting.
        #expect(error.code == "unavailable")
        #expect(ContinuousClock.now - started < .seconds(1))
        guard case .failure(let create) = await router.handle(ControlRequest(method: "workspace.create")) else { return }
        #expect(create.code == "unavailable")
    }

    @Test func pingAndCapabilitiesMergeBuiltins() async throws {
        let (router, _) = makeRouter()
        let ping = try await router.handle(ControlRequest(method: "system.ping")).get()
        #expect(ping["pong"] == true)
        let caps = try await router.handle(ControlRequest(method: "system.capabilities")).get()
        let methods = caps["methods"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(methods.contains("action.run") && methods.contains("surface.send_text") && methods.contains("workspace.create"))
        #expect(caps["version"] == 2)
    }

    @Test func v1LinesFallBackThroughProviders() async {
        let (router, _) = makeRouter()
        #expect(await router.response(forLine: "ping") == "PONG")
        #expect(await router.response(forLine: "agent_journal_append {}").hasPrefix("ERROR: unsupported in cmux-next"))
        #expect(await router.response(forLine: "report_pwd /tmp") == "OK")
        #expect(await router.response(forLine: "list_windows").hasPrefix("ERROR: cmux-next has not loaded"))
        #expect(await router.response(forLine: "bogus_verb").hasPrefix("ERROR: Unknown command 'bogus_verb'"))
    }

    @Test func deadlineTurnsHangsIntoTimeouts() async {
        await #expect(throws: ControlError.self) {
            try await CompatDeadline.run("hang", within: .milliseconds(50)) {
                try await ContinuousClock().sleep(for: .seconds(30))
                return 1
            }
        }
    }
}

@Suite struct CompatParsingTests {
    @Test func v1LineTokenizesQuotesOptionsAndTail() {
        let line = CompatV1Line(#"set_status build 'compiling now' --icon=hammer --priority 80 --tab=workspace:2"#)
        #expect(line.verb == "set_status")
        #expect(line.positional == ["build", "compiling now"])
        #expect(line.option("icon") == "hammer" && line.option("priority") == "80" && line.option("tab") == "workspace:2")
        let log = CompatV1Line(#"log --level=error -- "ship it" now"#)
        #expect(log.tail == ["ship it", "now"] && log.option("level") == "error")
        let flag = CompatV1Line("clear_agent_pid claude --clear-status")
        #expect(flag.has("clear-status") && flag.positional == ["claude"])
    }

    @Test func oldKeyNamesMapToDaemonChords() {
        #expect(CompatKeys.chord("Enter") == "enter")
        #expect(CompatKeys.chord("return") == "enter")
        #expect(CompatKeys.chord("ctrl-c") == "ctrl+c")
        #expect(CompatKeys.chord("ctrl+c") == "ctrl+c")
        #expect(CompatKeys.chord("sigint") == "ctrl+c")
        #expect(CompatKeys.chord("shift+tab") == "backtab")
        #expect(CompatKeys.chord("esc") == "escape")
        #expect(CompatKeys.chord("alt+f") == "alt+f")
        #expect(CompatKeys.chord("f12") == "f12")
        #expect(CompatKeys.chord("hyper+x") == nil)
        #expect(CompatKeys.chord("notakey") == nil)
    }

    @Test func sidebarStatusesSortByPriorityThenInsertion() {
        let store = CompatSidebarStore()
        store.setStatus("deploy", .init(value: "v1"), workspace: "W")
        store.setStatus("build", .init(value: "compiling", priority: 80), workspace: "W")
        store.setStatus("wrap", .init(value: "done", priority: 40), workspace: "W")
        let keys = CompatV1Sidebar.sortedStatuses(store.workspace("W")).map(\.key)
        #expect(keys == ["build", "wrap", "deploy"])
        for index in 0..<(CompatSidebarStore.logLimit + 5) {
            store.appendLog(.init(level: "info", message: "\(index)"), workspace: "W")
        }
        #expect(store.workspace("W").log.count == CompatSidebarStore.logLimit)
    }
}
