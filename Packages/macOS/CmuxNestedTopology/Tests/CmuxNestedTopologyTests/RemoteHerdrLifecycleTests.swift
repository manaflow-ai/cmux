import Foundation
import Testing
@testable import CmuxNestedTopology

@Suite struct RemoteHerdrLifecycleTests {
    private let socket = "/tmp/herdr.sock"
    private let session = RemoteHerdrDiscoveredSession(sessionID: "sess-1", name: "main", windowCount: 2)

    private func plan(
        _ target: RemoteHerdrAttachWindowTarget,
        enabled: Bool = true,
        appReady: Bool = true,
        alreadyAttaching: Bool = false,
        existingMirrorWindowID: String? = nil,
        sessions: [RemoteHerdrDiscoveredSession]? = nil,
        mirrors: [RemoteHerdrMirrorRecord] = [],
        liveSessionIDs: [String] = [],
        mirroredWorkspaceIDs: [String]? = nil
    ) -> RemoteHerdrAttachPlan {
        RemoteHerdrAttachPlanner.plan(
            target: target,
            enabled: enabled,
            appReady: appReady,
            alreadyAttaching: alreadyAttaching,
            existingMirrorWindowID: existingMirrorWindowID,
            activeWindowID: "win-active",
            liveWindows: ["win-active", "win-other"],
            sessions: sessions ?? [session],
            mirrors: mirrors,
            liveSessionIDs: liveSessionIDs,
            mirroredWorkspaceIDs: mirroredWorkspaceIDs
        )
    }

    @Test func socketValidation() {
        #expect(RemoteHerdrLifecycle.validateSocketPath("  /tmp/herdr.sock  ") == socket)
        #expect(RemoteHerdrLifecycle.validateSocketPath("tmp/herdr.sock") == nil)
        #expect(RemoteHerdrLifecycle.validateSocketPath("-oProxyCommand=x") == nil)
        #expect(RemoteHerdrLifecycle.validateSessionName("  main  ") == "main")
        let digest = RemoteHerdrLifecycle.endpointHash(socket)
        #expect(digest.count == 16)
        #expect(digest.allSatisfy({ $0.isHexDigit }))
        #expect(RemoteHerdrLifecycle.endpointHash("/tmp/other.sock") != digest)
    }

    @Test func betaFlag() {
        #expect(RemoteHerdrLifecycle.settingKey == "remoteHerdrMirror.beta.enabled")
        #expect(RemoteHerdrLifecycle.decodeBeta(nil) == false)
        #expect(RemoteHerdrLifecycle.decodeBeta("on") == true)
        #expect(RemoteHerdrLifecycle.decodeBeta("off") == false)
    }

    @Test func existingMirrorAffinityBeatsExplicit() {
        let target = RemoteHerdrAttachWindowTarget(kind: "explicit", windowID: "win-other")
        let resolved = target.resolve(
            existingMirrorWindowID: "win-active",
            activeWindowID: "win-other",
            isLive: { _ in true }
        )
        #expect(resolved == "win-active")
    }

    @Test func explicitDeadWindowFailsClosed() {
        let target = RemoteHerdrAttachWindowTarget(kind: "explicit", windowID: "win-dead")
        #expect(
            target.resolve(
                existingMirrorWindowID: nil,
                activeWindowID: "win-active",
                isLive: { $0 == "win-active" }
            ) == nil
        )
    }

    @Test func unresolvedExplicitNeverFallsBack() {
        let target = RemoteHerdrAttachWindowTarget(kind: "unresolved_explicit")
        #expect(
            target.resolve(
                existingMirrorWindowID: nil,
                activeWindowID: "win-active",
                isLive: { _ in true }
            ) == nil
        )
    }

    @Test func contextualFallsBackToActive() {
        let target = RemoteHerdrAttachWindowTarget(kind: "contextual", windowID: "win-dead")
        #expect(
            target.resolve(
                existingMirrorWindowID: nil,
                activeWindowID: "win-active",
                isLive: { $0 == "win-active" }
            ) == "win-active"
        )
    }

    @Test func preflightRejectsBeforeDiscovery() {
        let plan = RemoteHerdrAttachPlanner.plan(
            target: RemoteHerdrAttachWindowTarget(kind: "unresolved_explicit"),
            enabled: true,
            appReady: true,
            alreadyAttaching: false,
            existingMirrorWindowID: nil,
            activeWindowID: "win-active",
            liveWindows: ["win-active"],
            sessions: nil
        )
        #expect(plan.outcome == "invalid_target")
    }

    @Test func disabledUnreadyReentrant() {
        let target = RemoteHerdrAttachWindowTarget(kind: "contextual")
        #expect(plan(target, enabled: false).outcome == "disabled")
        #expect(plan(target, appReady: false).outcome == "unreachable")
        #expect(plan(target, alreadyAttaching: true).outcome == "already_attaching")
    }

    @Test func emptyDiscoveryDoesNotCreateChrome() {
        let result = plan(
            RemoteHerdrAttachWindowTarget(kind: "dedicated_new_window"),
            sessions: []
        )
        #expect(result.outcome == "no_sessions")
        #expect(result.createWindow == false)
    }

    @Test func dedicatedCreatesOnlyAfterSessions() {
        let result = plan(RemoteHerdrAttachWindowTarget(kind: "dedicated_new_window"))
        #expect(result.outcome == "mirrored")
        #expect(result.createWindow)
        #expect(result.discardWindowOnFail)
        #expect(result.sessionsToMirror == ["sess-1"])
        #expect(result.postAttach == RemoteHerdrLifecycle.postApplyClientSize)
    }

    @Test func reuseLiveConnection() {
        let result = plan(
            RemoteHerdrAttachWindowTarget(kind: "contextual"),
            mirrors: [RemoteHerdrMirrorRecord(sessionID: "sess-1", windowID: "win-active", workspaceID: "ws-1")],
            liveSessionIDs: ["sess-1"]
        )
        #expect(result.outcome == "reused")
        #expect(result.sessionsToReuse == ["sess-1"])
        #expect(result.sessionsToMirror.isEmpty)
    }

    @Test func deadMirrorIsPurgedAndRemirrored() {
        let result = plan(
            RemoteHerdrAttachWindowTarget(kind: "contextual"),
            mirrors: [RemoteHerdrMirrorRecord(sessionID: "sess-1", windowID: "win-active", workspaceID: nil)],
            liveSessionIDs: ["sess-1"]
        )
        #expect(result.purgeSessionIDs == ["sess-1"])
        #expect(result.sessionsToMirror == ["sess-1"])
        #expect(result.outcome == "mirrored")
    }

    @Test func connectionReuseAndCache() {
        #expect(RemoteHerdrLifecycle.connectionAction(started: true, exited: false, exists: false) == "start")
        #expect(RemoteHerdrLifecycle.connectionAction(started: false, exited: false, exists: false) == "start")
        #expect(RemoteHerdrLifecycle.connectionAction(started: true, exited: false, exists: true) == "reuse")
        #expect(RemoteHerdrLifecycle.connectionAction(started: false, exited: false, exists: true) == "start")
        #expect(RemoteHerdrLifecycle.connectionAction(started: true, exited: true, exists: true) == "replace")
        #expect(RemoteHerdrLifecycle.mayCacheConnection(started: false, exited: false) == false)
        #expect(RemoteHerdrLifecycle.mayCacheConnection(started: true, exited: false) == true)
        #expect(RemoteHerdrLifecycle.postAttachAction(replacedDead: true) == RemoteHerdrLifecycle.postReseed)
    }

    @Test func reentrantGuard() {
        var registry = RemoteHerdrAttachRegistry()
        let first = registry.beginAttach("abc")
        #expect(first)
        let second = registry.beginAttach("abc")
        #expect(second == false)
        registry.endAttach("abc")
        let third = registry.beginAttach("abc")
        #expect(third)
    }

    @Test func everyHostCloseDetaches() {
        for source in [
            "last_workspace_tab",
            "window_quit",
            "app_terminate",
            "explicit_detach",
            "host_tab",
            "host_panel",
        ] {
            #expect(RemoteHerdrLifecycle.hostClosePolicy(source) == "detach")
        }
        #expect(RemoteHerdrLifecycle.hostClosePolicy("unknown") == "noop")
    }

    @Test func restoreReattachesNotReplayTree() {
        let record = RemoteHerdrRestoreRecord(
            endpointHash: "abc",
            socketPath: socket,
            sessionIDs: ["sess-1"],
            targetKind: "explicit",
            windowID: "win-stale"
        )
        let result = RemoteHerdrAttachPlanner.planRestore(
            record,
            enabled: true,
            appReady: true,
            sessions: [session],
            liveWindows: ["win-active"],
            activeWindowID: "win-active"
        )
        #expect(result.outcome == "mirrored")
        #expect(result.postAttach == RemoteHerdrLifecycle.postReseed)
        #expect(result.reason == "restore_reattach")
        #expect(record.dictionary()["mode"] as? String == "reattach")
        #expect(RemoteHerdrRestoreRecord.fromDictionary(["mode": "replay_tree"]) == nil)
    }

    @Test func dispatchGatesAndValidates() {
        #expect(
            RemoteHerdrAttachPlanner.dispatch(
                method: "remote.herdr.sessions",
                params: ["socket": socket],
                enabled: false
            )["code"] as? String == "disabled"
        )
        #expect(
            RemoteHerdrAttachPlanner.dispatch(
                method: "remote.tmux.attach",
                params: ["socket": socket],
                enabled: true
            )["code"] as? String == "unknown_method"
        )
        let ok = RemoteHerdrAttachPlanner.dispatch(
            method: "remote.herdr.attach",
            params: ["socket": socket, "session": "main", "activate": true],
            enabled: true
        )
        #expect(ok["ok"] as? Bool == true)
        #expect(ok["activate"] as? Bool == true)
        #expect(RemoteHerdrLifecycle.socketMethods.count == 8)
    }

    @Test func paneGridsMatchContract() {
        #expect(
            RemoteHerdrLifecycle.gridMatch(
                assignedCols: 80, assignedRows: 24,
                renderedCols: 80, renderedRows: 24,
                exactCols: true, exactRows: true
            )
        )
        #expect(
            RemoteHerdrLifecycle.gridMatch(
                assignedCols: 80, assignedRows: 24,
                renderedCols: 79, renderedRows: 24,
                exactCols: true, exactRows: false
            ) == false
        )
        #expect(
            RemoteHerdrLifecycle.gridMatch(
                assignedCols: 80, assignedRows: 24,
                renderedCols: 80, renderedRows: 30,
                exactCols: true, exactRows: false
            )
        )
    }
}
