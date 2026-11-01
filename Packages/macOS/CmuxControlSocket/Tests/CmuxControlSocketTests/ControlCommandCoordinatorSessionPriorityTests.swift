import Foundation
import Testing
@testable import CmuxControlSocket

/// A scriptable ``ControlCommandContext`` for driving the session-priority
/// coordinator domain without the app target.
@MainActor
final class FakeSessionPriorityControlCommandContext: ControlCommandContext {
    var resolution: ControlSessionPriorityResolution = .tabManagerUnavailable
    var probe: ControlSessionPriorityProbe?
    var statusResolution: ControlSessionPriorityStatusResolution = .tabManagerUnavailable

    var lastWorkspaceID: UUID??
    var lastSet: (difficultyRaw: String?, clearDifficulty: Bool, manual: Bool?, source: String)?
    var setCalls = 0

    func controlSessionPriority(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?
    ) -> ControlSessionPriorityResolution {
        lastWorkspaceID = workspaceID
        return resolution
    }

    func controlSetSessionPriority(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        difficultyRaw: String?,
        clearDifficulty: Bool,
        manual: Bool?,
        source: String
    ) -> ControlSessionPriorityResolution {
        setCalls += 1
        lastWorkspaceID = workspaceID
        lastSet = (difficultyRaw, clearDifficulty, manual, source)
        return resolution
    }

    func controlProbeSessionPriority(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?
    ) -> ControlSessionPriorityProbe? {
        lastWorkspaceID = workspaceID
        return probe
    }

    func controlSessionPriorityStatus(
        routing: ControlRoutingSelectors
    ) -> ControlSessionPriorityStatusResolution { statusResolution }
}

@MainActor
@Suite("ControlCommandCoordinator session-priority domain")
struct ControlCommandCoordinatorSessionPriorityTests {
    private let workspaceID = UUID()
    private let windowID = UUID()
    private let surfaceID = UUID()

    private func snapshot() -> ControlSessionPrioritySnapshot {
        ControlSessionPrioritySnapshot(
            workspaceId: workspaceID,
            enabled: true,
            tier: "urgent",
            difficulty: "hard",
            difficultySource: "override",
            difficultyOverride: "hard",
            difficultyAuto: nil,
            manual: false,
            manualSignal: nil,
            targetEffort: "high",
            targetModel: nil,
            panes: [.init(
                surfaceId: surfaceID, sessionId: "s1", currentEffort: "medium",
                state: "held", detail: "held.draft"
            )]
        )
    }

    private func run(
        _ method: String,
        _ params: [String: JSONValue],
        _ context: FakeSessionPriorityControlCommandContext
    ) throws -> ControlCallResult {
        let coordinator = ControlCommandCoordinator(context: context)
        return try #require(coordinator.handle(
            ControlRequest(id: .int(1), method: method, params: params)
        ))
    }

    private func errorCode(_ result: ControlCallResult) -> String? {
        if case .err(let code, _, _) = result { return code }
        return nil
    }

    private func payload(_ result: ControlCallResult) -> [String: JSONValue]? {
        if case .ok(.object(let object)) = result { return object }
        return nil
    }

    @Test func getRoutesWorkspaceId() throws {
        let context = FakeSessionPriorityControlCommandContext()
        context.resolution = .resolved(windowID: windowID, snapshot: snapshot())
        let result = try run("session_priority.get", ["workspace_id": .string(workspaceID.uuidString)], context)
        #expect(context.lastWorkspaceID == .some(workspaceID))
        let object = payload(result)
        #expect(object?["workspace_id"] == .string(workspaceID.uuidString))
        #expect(object?["window_id"] == .string(windowID.uuidString))
        #expect(object?["difficulty_source"] == .string("override"))
        #expect(object?["difficulty_auto"] == .null)
        #expect(object?["target"] == .object(["effort": .string("high"), "model": .null]))
        guard case .array(let panes)? = object?["panes"], case .object(let pane)? = panes.first else {
            Issue.record("panes missing")
            return
        }
        #expect(pane["surface_id"] == .string(surfaceID.uuidString))
        #expect(pane["state"] == .string("held"))
        #expect(pane["detail"] == .string("held.draft"))
    }

    /// The CLI prints the workspace in the requested `--id-format`, which needs its ref next to
    /// its id, as the workspace-todo status payload carries them.
    @Test func payloadsCarryWorkspaceAndWindowRefs() throws {
        let context = FakeSessionPriorityControlCommandContext()
        context.resolution = .resolved(windowID: windowID, snapshot: snapshot())
        context.statusResolution = .resolved(
            windowID: windowID, enabled: true, urgentCount: 1, workspaces: [snapshot()]
        )
        let coordinator = ControlCommandCoordinator(context: context)
        func call(_ method: String, _ params: [String: JSONValue]) throws -> [String: JSONValue]? {
            payload(try #require(coordinator.handle(ControlRequest(id: .int(1), method: method, params: params))))
        }

        let get = try call("session_priority.get", ["workspace_id": .string(workspaceID.uuidString)])
        let set = try call("session_priority.set", ["difficulty": .string("hard")])
        let status = try call("session_priority.status", [:])

        #expect(get?["workspace_ref"] == .string("workspace:1"))
        #expect(get?["window_ref"] == .string("window:1"))
        #expect(set?["workspace_ref"] == .string("workspace:1"))
        #expect(status?["window_ref"] == .string("window:1"))
        guard case .array(let workspaces)? = status?["workspaces"], case .object(let workspace)? = workspaces.first else {
            Issue.record("workspaces missing")
            return
        }
        #expect(workspace["workspace_id"] == .string(workspaceID.uuidString))
        #expect(workspace["workspace_ref"] == .string("workspace:1"))
    }

    @Test func getWithoutManagerIsUnavailable() throws {
        let result = try run("session_priority.get", [:], FakeSessionPriorityControlCommandContext())
        #expect(errorCode(result) == "unavailable")
    }

    @Test func setRejectsEmptyRequest() throws {
        let context = FakeSessionPriorityControlCommandContext()
        let result = try run("session_priority.set", [:], context)
        #expect(errorCode(result) == "invalid_params")
        #expect(context.setCalls == 0)
    }

    @Test func setAutoSourceRequiresDifficulty() throws {
        let context = FakeSessionPriorityControlCommandContext()
        #expect(errorCode(try run("session_priority.set", ["source": .string("auto")], context)) == "invalid_params")
        #expect(errorCode(try run(
            "session_priority.set",
            ["source": .string("auto"), "difficulty": .string("auto")],
            context
        )) == "invalid_params")
        #expect(context.setCalls == 0)
    }

    @Test func setAutoSourceForbidsManual() throws {
        let context = FakeSessionPriorityControlCommandContext()
        let result = try run(
            "session_priority.set",
            ["source": .string("auto"), "difficulty": .string("hard"), "manual": .bool(true)],
            context
        )
        #expect(errorCode(result) == "invalid_params")
        #expect(context.setCalls == 0)
    }

    @Test func setRejectsUnknownSource() throws {
        let context = FakeSessionPriorityControlCommandContext()
        let result = try run(
            "session_priority.set",
            ["source": .string("bogus"), "difficulty": .string("hard")],
            context
        )
        #expect(errorCode(result) == "invalid_params")
        #expect(context.setCalls == 0)
    }

    @Test func setMapsAutoToClear() throws {
        let context = FakeSessionPriorityControlCommandContext()
        context.resolution = .resolved(windowID: windowID, snapshot: snapshot())
        _ = try run("session_priority.set", ["difficulty": .string("auto")], context)
        #expect(context.lastSet?.clearDifficulty == true)
        #expect(context.lastSet?.difficultyRaw == nil)
        #expect(context.lastSet?.source == "user")

        _ = try run("session_priority.set", ["difficulty": .string("hard"), "manual": .bool(true)], context)
        #expect(context.lastSet?.clearDifficulty == false)
        #expect(context.lastSet?.difficultyRaw == "hard")
        #expect(context.lastSet?.manual == true)

        _ = try run("session_priority.set", ["difficulty": .string("easy"), "source": .string("auto")], context)
        #expect(context.lastSet?.source == "auto")
        #expect(context.lastSet?.difficultyRaw == "easy")
    }

    private func autoSet(_ context: FakeSessionPriorityControlCommandContext, source: String = "auto") throws -> ControlCallResult {
        try run(
            "session_priority.set",
            [
                "workspace_id": .string(workspaceID.uuidString),
                "difficulty": .string("hard"),
                "source": .string(source),
            ],
            context
        )
    }

    /// A rating that arrives after session priority went off changes nothing, so turning it back
    /// on does not bring back a stale automatic difficulty. The reply is the workspace as it is.
    @Test func autoSetWhileDisabledIsNotStored() throws {
        let context = FakeSessionPriorityControlCommandContext()
        context.probe = ControlSessionPriorityProbe(
            enabled: false, workspaceId: workspaceID, manual: false, overridePresent: false,
            adjustable: true, difficultyAuto: nil
        )
        context.resolution = .resolved(windowID: windowID, snapshot: snapshot())
        let object = payload(try autoSet(context))
        #expect(context.setCalls == 0)
        #expect(object?["workspace_id"] == .string(workspaceID.uuidString))
        #expect(context.lastWorkspaceID == .some(workspaceID))
    }

    @Test func autoSetWhileEnabledIsStored() throws {
        let context = FakeSessionPriorityControlCommandContext()
        context.probe = ControlSessionPriorityProbe(
            enabled: true, workspaceId: workspaceID, manual: false, overridePresent: false,
            adjustable: true, difficultyAuto: nil
        )
        context.resolution = .resolved(windowID: windowID, snapshot: snapshot())
        _ = try autoSet(context)
        #expect(context.setCalls == 1)
        #expect(context.lastSet?.source == "auto")
        #expect(context.lastSet?.difficultyRaw == "hard")
    }

    /// Only the automatic value is dropped: a difficulty the user sets while off is kept.
    @Test func userSetWhileDisabledIsStillStored() throws {
        let context = FakeSessionPriorityControlCommandContext()
        context.probe = ControlSessionPriorityProbe(
            enabled: false, workspaceId: workspaceID, manual: false, overridePresent: false,
            adjustable: true, difficultyAuto: nil
        )
        context.resolution = .resolved(windowID: windowID, snapshot: snapshot())
        _ = try autoSet(context, source: "user")
        #expect(context.setCalls == 1)
        #expect(context.lastSet?.source == "user")
    }

    @Test func setSurfacesInvalidDifficulty() throws {
        let context = FakeSessionPriorityControlCommandContext()
        context.resolution = .invalidDifficulty("brutal")
        let result = try run("session_priority.set", ["difficulty": .string("brutal")], context)
        #expect(errorCode(result) == "invalid_difficulty")
    }

    @Test func probeReturnsProbePayload() throws {
        let context = FakeSessionPriorityControlCommandContext()
        context.probe = ControlSessionPriorityProbe(
            enabled: true, workspaceId: workspaceID, manual: true, overridePresent: false,
            adjustable: false, difficultyAuto: "hard"
        )
        let result = try run("session_priority.set", ["probe": .bool(true)], context)
        let object = payload(result)
        #expect(object?["enabled"] == .bool(true))
        #expect(object?["workspace_id"] == .string(workspaceID.uuidString))
        #expect(object?["manual"] == .bool(true))
        #expect(object?["override_present"] == .bool(false))
        // The difficulty hook skips its rating call for a workspace cmux leaves alone.
        #expect(object?["adjustable"] == .bool(false))
        // The difficulty hook damps against the workspace's current automatic rating.
        #expect(object?["difficulty_auto"] == .string("hard"))
        #expect(context.setCalls == 0)
    }

    @Test func probeWithoutWorkspaceIsNotFound() throws {
        let context = FakeSessionPriorityControlCommandContext()
        let result = try run("session_priority.set", ["probe": .bool(true)], context)
        #expect(errorCode(result) == "not_found")
    }

    @Test func statusListsWorkspaces() throws {
        let context = FakeSessionPriorityControlCommandContext()
        context.statusResolution = .resolved(
            windowID: windowID, enabled: true, urgentCount: 2, workspaces: [snapshot()]
        )
        let object = payload(try run("session_priority.status", [:], context))
        #expect(object?["window_id"] == .string(windowID.uuidString))
        #expect(object?["enabled"] == .bool(true))
        #expect(object?["urgent_count"] == .int(2))
        guard case .array(let workspaces)? = object?["workspaces"] else {
            Issue.record("workspaces missing")
            return
        }
        #expect(workspaces.count == 1)
    }
}
