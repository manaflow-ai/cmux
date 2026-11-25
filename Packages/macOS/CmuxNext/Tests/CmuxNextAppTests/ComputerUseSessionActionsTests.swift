import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextComputerUse
import Foundation
import Testing

/// Focus Computer Use, Focus Calling Terminal and Stop Computer Use (`computerUseFocus`,
/// `computerUseFocusCallingTerminal`, `computerUseStop`; File menu, `cmux agent ...`): each acts
/// on the newest live session the CUA host lists (`activity_sessions_list`), as classic's menu bar
/// item acted on its first row. They are working actions, not rows disabled forever.
@MainActor @Suite(.serialized)
struct ComputerUseSessionActionsTests {
    /// A CUA host with canned live sessions that records each stop.
    @MainActor final class FakeSessions: ComputerUseSessionControlling {
        var sessions: [ComputerUseLiveSession]
        var failure: ComputerUseSessionError?
        private(set) var stopped: [String] = []
        init(_ sessions: [ComputerUseLiveSession]) { self.sessions = sessions }
        func liveSessions() async throws -> [ComputerUseLiveSession] {
            if let failure { throw failure }
            return sessions
        }
        func stop(_ id: String) async throws { stopped.append(id) }
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

    static let older = ComputerUseLiveSession(
        id: "cua_old", lastActionAt: Date(timeIntervalSince1970: 100),
        target: .init(pid: 41, bundleID: "com.apple.Notes", appName: "Notes"), terminalID: "term_old", workspaceID: "ws_1")
    static let newer = ComputerUseLiveSession(
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

    @Test func stopStopsTheNewestLiveSession() async {
        let sessions = FakeSessions([Self.older, Self.newer])
        let registry = Self.registry(sessions, FakeFocus())
        #expect(await Self.run("computerUseStop", registry) == nil)
        #expect(sessions.stopped == ["cua_new"])
    }

    @Test func focusComputerUseRaisesTheNewestSessionsTarget() async {
        let focus = FakeFocus()
        let registry = Self.registry(FakeSessions([Self.newer, Self.older]), focus)
        #expect(await Self.run("computerUseFocus", registry) == nil)
        #expect(focus.raisedTargets == ["cua_new"])
    }

    @Test func focusCallingTerminalRevealsTheTerminalThatStartedIt() async {
        let focus = FakeFocus()
        let registry = Self.registry(FakeSessions([Self.older, Self.newer]), focus)
        #expect(await Self.run("computerUseFocusCallingTerminal", registry) == nil)
        #expect(focus.revealedTerminals == ["term_new"])
    }

    @Test(arguments: ["computerUseFocus", "computerUseFocusCallingTerminal", "computerUseStop"])
    func withNoLiveSessionEachActionSaysSo(id: String) async {
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
        #expect(sessions.stopped.isEmpty)
    }
}
