import CmuxNextDaemon
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Synchronization
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
        #expect(await router.response(forLine: "agent_journal_append {}") == "ERROR: invalid agent journal event")
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

/// Compat mutations run registry actions through the executor (the shared
/// keyboard/menu/palette path) and wait for the work the handler tracked.
@Suite struct CompatActionTests {
    final class TrackingExecutor: ControlActionExecutor {
        let requests = Mutex<[ControlActionRequest]>([])
        let outcome: ControlActionOutcome
        let failure: String?
        init(outcome: ControlActionOutcome = .ran, failure: String? = nil) {
            self.outcome = outcome
            self.failure = failure
        }
        func performAction(_ request: ControlActionRequest) -> ControlActionOutcome {
            requests.withLock { $0.append(request) }
            return outcome
        }
        func performActionTracked(_ request: ControlActionRequest) -> ControlActionRun {
            let failure = failure
            return ControlActionRun(outcome: performAction(request), work: [Task { failure }])
        }
    }

    /// The service holds its router weakly; the caller keeps both alive.
    func install(_ executor: TrackingExecutor) -> (CompatService, ControlRouter) {
        let router = ControlRouter(identity: testIdentity(), executor: executor)
        let service = CompatService(frontend: HeadlessCompatFrontend()) { nil }
        service.install(on: router)
        return (service, router)
    }

    @Test func runsTheRegistryActionWithTargetAndArguments() async throws {
        let executor = TrackingExecutor()
        let (service, router) = install(executor)
        defer { withExtendedLifetime(router) {} }
        try await service.runAction("splitRight", target: ControlTargetRef(kind: "pane", id: "pane_1"),
                                    arguments: ["cwd": .string("/tmp")], connection: .inProcess, method: "surface.split",
                                    deadline: .now + .seconds(2))
        let request = try #require(executor.requests.withLock { $0.last })
        #expect(request.actionID == "splitRight")
        #expect(request.target == ControlTargetRef(kind: "pane", id: "pane_1"))
        #expect(request.arguments["cwd"] == .string("/tmp"))
    }

    @Test func refusalsAndDaemonFailuresComeBackTyped() async {
        let (refused, keepA) = install(TrackingExecutor(outcome: .refused("not shown in any window")))
        defer { withExtendedLifetime(keepA) {} }
        await #expect(throws: ControlError.self) {
            try await refused.runAction("closeTab", connection: .inProcess, method: "surface.close", deadline: .now + .seconds(2))
        }
        let (failing, keepB) = install(TrackingExecutor(failure: "split: PTY capacity exhausted"))
        defer { withExtendedLifetime(keepB) {} }
        do {
            try await failing.runAction("splitDown", connection: .inProcess, method: "surface.split", deadline: .now + .seconds(2))
            Issue.record("expected failure")
        } catch let error as ControlError {
            #expect(error.code == "daemon_error" && error.message.contains("PTY capacity"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

extension CompatActionTests {
    @Test func actionRunWaitsForTrackedWorkOnlyWhenAsked() async throws {
        let executor = TrackingExecutor(failure: "new-tab: PTY capacity exhausted")
        let router = ControlRouter(identity: testIdentity(), executor: executor)
        router.updateCatalog(sampleCatalog())
        let action = try #require(router.catalog.actions.first(where: { $0.arguments.allSatisfy { !$0.isRequired } && $0.requires.isEmpty }))
        let quick = await router.handle(ControlRequest(method: "action.run", params: ["action": .string(action.id)]))
        #expect(try quick.get()["waited"] == false)
        guard case .failure(let error) = await router.handle(ControlRequest(method: "action.run", params: ["action": .string(action.id), "wait": true])) else {
            Issue.record("expected the tracked failure")
            return
        }
        #expect(error.code == "daemon_error")
    }
}
