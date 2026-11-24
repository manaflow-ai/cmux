import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextComputerUse
import Foundation
import Testing

/// Focus Computer Use, Focus Calling Terminal and Stop Computer Use (`computerUseFocus`,
/// `computerUseFocusCallingTerminal`, `computerUseStop`; File menu, `cmux agent ...`): the focus
/// actions act on the newest live session the host lists, as classic's menu bar item acted on its
/// first row; Stop ends every session. They are working actions, not rows disabled forever.
@MainActor @Suite(.serialized)
struct ComputerUseSessionActionsTests {
    /// A CUA host with canned live sessions that records each stop.
    @MainActor final class FakeSessions: ComputerUseSessionControlling {
        var sessions: [ComputerUseLiveSession]
        var failure: ComputerUseSessionError?
        private(set) var stopped: [String] = []
        private(set) var stoppedAll = 0
        init(_ sessions: [ComputerUseLiveSession]) { self.sessions = sessions }
        func liveSessions() async throws -> [ComputerUseLiveSession] {
            if let failure { throw failure }
            return sessions
        }
        private(set) var raisedWindows: [String] = []
        func stop(_ id: String) async throws {
            if let failure { throw failure }
            stopped.append(id)
        }
        func stopAll() async throws {
            if let failure { throw failure }
            stoppedAll += 1
        }
        func raiseWindow(_ id: String) async throws { raisedWindows.append(id) }
    }

    /// Records what the actions bring forward.
    @MainActor final class FakeFocus: ComputerUseFocusing {
        private(set) var raisedTargets: [String] = []
        private(set) var revealedTerminals: [String] = []
        var finds = true
        func raiseTarget(of session: ComputerUseLiveSession) -> Bool {
            guard finds, session.target != nil else { return false }
            raisedTargets.append(session.id)
            return true
        }
        func revealCallingTerminal(of session: ComputerUseLiveSession) -> Bool {
            guard finds, let terminal = session.terminalID else { return false }
            revealedTerminals.append(terminal)
            return true
        }
    }

    nonisolated static let older = ComputerUseLiveSession(
        id: "cua_old", lastActionAt: Date(timeIntervalSince1970: 100),
        target: .init(pid: 41, bundleID: "com.apple.Notes", appName: "Notes"), terminalID: "term_old", workspaceID: "ws_1")
    nonisolated static let newer = ComputerUseLiveSession(
        id: "cua_new", lastActionAt: Date(timeIntervalSince1970: 200),
        target: .init(pid: 42, bundleID: "com.apple.Safari", appName: "Safari"), terminalID: "term_new", workspaceID: "ws_1")

    static func registry(_ sessions: FakeSessions, _ focus: FakeFocus) -> ActionRegistry {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        ComputerUseHandlers.bind(into: services.registry, sessions: sessions, focus: focus)
        return services.registry
    }

    /// Runs `id` like the CLI does and returns the refusal, after the tracked work finishes.
    static func run(_ id: ActionID, _ registry: ActionRegistry) async -> String? {
        var work: [ActionWork] = []
        let refusal = registry.capturingRefusal {
            work = registry.capturingWork { _ = registry.perform(id, invocation: ActionInvocation(origin: .cli)) }
        }
        var failure: String? = refusal
        for task in work {
            if let failed = await task.value { failure = failure ?? failed.description }
        }
        return failure
    }

    @Test(arguments: ["computerUseFocus", "computerUseFocusCallingTerminal", "computerUseStop"])
    func theThreeActionsAreWorkingActions(id: String) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        #expect(services.registry.unavailableReason(for: ActionID(rawValue: id)) == nil)
    }

    @Test func theHostsListBecomesLiveSessionsNewestFirst() {
        let result: [String: Any] = ["sessions": [
            ["id": "cua_a", "status": ["state": "active"], "last_action_at_ms": 1_000,
             "agent": ["terminal_id": "term_a", "workspace_id": "ws_a"],
             "targets": [["app_name": "Notes", "app_bundle_id": "com.apple.Notes", "pid": 41, "window_id": 7]]],
            ["id": "cua_gone", "status": ["state": "ended", "reason": "agent_end"], "last_action_at_ms": 9_000],
            ["id": "cua_b", "status": ["state": "idle"], "last_action_at_ms": 5_000,
             "agent": [:], "targets": [["app_name": "Safari", "pid": 42]]],
        ]]
        let sessions = ComputerUseLiveSession.live(from: result)
        #expect(sessions.map(\.id) == ["cua_b", "cua_a"])
        #expect(sessions[1].target == .init(pid: 41, bundleID: "com.apple.Notes", appName: "Notes"))
        #expect(sessions[1].terminalID == "term_a")
        #expect(sessions[0].terminalID == nil)
        #expect(sessions[0].target?.pid == 42)
    }

    /// Stop ends every session, whether or not the host lists them.
    @Test(arguments: [[], [ComputerUseSessionActionsTests.older, ComputerUseSessionActionsTests.newer]])
    func stopStopsEverySession(_ live: [ComputerUseLiveSession]) async {
        let sessions = FakeSessions(live)
        let registry = Self.registry(sessions, FakeFocus())
        #expect(await Self.run("computerUseStop", registry) == nil)
        #expect(sessions.stoppedAll == 1)
        #expect(sessions.stopped.isEmpty)
    }

    @Test func focusComputerUseRaisesTheNewestSessionsTarget() async {
        let focus = FakeFocus()
        let sessions = FakeSessions([Self.newer, Self.older])
        let registry = Self.registry(sessions, focus)
        #expect(await Self.run("computerUseFocus", registry) == nil)
        #expect(focus.raisedTargets == ["cua_new"])
        #expect(sessions.raisedWindows == ["cua_new"], "its window first, then its app")
    }

    /// Runs `id` with a `session` argument, as the menu bar's per-agent rows do.
    static func run(_ id: ActionID, session: String, _ registry: ActionRegistry) async -> String? {
        var work: [ActionWork] = []
        let refusal = registry.capturingRefusal {
            work = registry.capturingWork {
                _ = registry.perform(id, invocation: ActionInvocation(arguments: ["session": .string(session)]))
            }
        }
        var failure: String? = refusal
        for task in work {
            if let failed = await task.value { failure = failure ?? failed.description }
        }
        return failure
    }

    /// The menu bar's per-agent Stop stops that agent only.
    @Test func stopWithASessionStopsThatSessionOnly() async {
        let sessions = FakeSessions([Self.older, Self.newer])
        let registry = Self.registry(sessions, FakeFocus())
        #expect(await Self.run("computerUseStop", session: "cua_old", registry) == nil)
        #expect(sessions.stopped == ["cua_old"])
        #expect(sessions.stoppedAll == 0)
    }

    /// The menu bar's per-agent Show Window shows that agent's window, not the newest one's.
    @Test func showWindowWithASessionRaisesThatSessionsWindowAndApp() async {
        let focus = FakeFocus()
        let sessions = FakeSessions([Self.newer, Self.older])
        let registry = Self.registry(sessions, focus)
        #expect(await Self.run("computerUseFocus", session: "cua_old", registry) == nil)
        #expect(sessions.raisedWindows == ["cua_old"] && focus.raisedTargets == ["cua_old"])
        #expect(await Self.run("computerUseFocus", session: "cua_gone", registry) == ComputerUseSessionStrings.noLiveSession)
    }

    @Test func focusCallingTerminalRevealsTheTerminalThatStartedIt() async {
        let focus = FakeFocus()
        let registry = Self.registry(FakeSessions([Self.older, Self.newer]), focus)
        #expect(await Self.run("computerUseFocusCallingTerminal", registry) == nil)
        #expect(focus.revealedTerminals == ["term_new"])
    }

    @Test(arguments: ["computerUseFocus", "computerUseFocusCallingTerminal"])
    func withNoLiveSessionEachFocusActionSaysSo(id: String) async {
        let sessions = FakeSessions([])
        let registry = Self.registry(sessions, FakeFocus())
        #expect(await Self.run(ActionID(rawValue: id), registry) == ComputerUseSessionStrings.noLiveSession)
        #expect(sessions.stopped.isEmpty)
    }

    @Test func aSessionWithoutATerminalSaysSo() async {
        var session = Self.newer
        session.terminalID = nil
        let registry = Self.registry(FakeSessions([session]), FakeFocus())
        #expect(await Self.run("computerUseFocusCallingTerminal", registry) == ComputerUseSessionStrings.noCallingTerminal)
    }

    @Test func aSessionWithoutATargetSaysSo() async {
        var session = Self.newer
        session.target = nil
        let registry = Self.registry(FakeSessions([session]), FakeFocus())
        #expect(await Self.run("computerUseFocus", registry) == ComputerUseSessionStrings.noTarget)
    }

    @Test func withComputerUseOffTheActionGivesThatReason() async {
        let sessions = FakeSessions([Self.newer])
        sessions.failure = .notRunning(ComputerUseSessionStrings.off)
        let registry = Self.registry(sessions, FakeFocus())
        #expect(await Self.run("computerUseStop", registry) == ComputerUseSessionStrings.off)
        #expect(sessions.stoppedAll == 0)
    }
}
