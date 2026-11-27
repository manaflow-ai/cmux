import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
struct ControlWorkspaceReorderTargetTests {
    @Test(arguments: ["before_workspace_id", "after_workspace_id"])
    func unresolvedRelativeTargetReportsNotFound(key: String) {
        let context = FakeWorkspaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let result = coordinator.handle(ControlRequest(id: .int(1), method: "workspace.reorder", params: [
            "workspace_id": .string(UUID().uuidString),
            key: .string("workspace:999999"),
            "dry_run": .bool(true)
        ]))
        guard case .err(let code, _, _) = result else {
            Issue.record("An unknown relative target must fail")
            return
        }
        #expect(code == "not_found")
        #expect(context.reorderCall == nil)
    }

    @Test(arguments: ["before_workspace_id", "after_workspace_id"])
    func unresolvedTargetStillConflictsWithIndex(key: String) {
        let context = FakeWorkspaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let result = coordinator.handle(ControlRequest(id: .int(1), method: "workspace.reorder", params: [
            "workspace_id": .string(UUID().uuidString),
            key: .string("workspace:999999"),
            "index": .int(0)
        ]))
        guard case .err(let code, _, _) = result else {
            Issue.record("Conflicting targets must fail")
            return
        }
        #expect(code == "invalid_params")
        #expect(context.reorderCall == nil)
    }

    @Test(arguments: ["before_workspace_id", "after_workspace_id"], [true, false])
    func knownRelativeTargetReachesPlannerWithoutIndex(key: String, dryRun: Bool) throws {
        let context = FakeWorkspaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()
        let targetID = UUID()
        let workspaceRef = coordinator.ensureRef(kind: .workspace, uuid: workspaceID)
        let targetRef = coordinator.ensureRef(kind: .workspace, uuid: targetID)
        context.reorderResolution = .resolved(
            windowID: nil,
            plan: ControlWorkspaceReorderPlanItem(workspaceID: workspaceID, fromIndex: 1, toIndex: 0)
        )
        let result = coordinator.handle(ControlRequest(id: .int(1), method: "workspace.reorder", params: [
            "workspace_id": .string(workspaceRef), key: .string(targetRef), "dry_run": .bool(dryRun)
        ]))
        guard case .ok = result else {
            Issue.record("A known relative target must succeed")
            return
        }
        let call = try #require(context.reorderCall)
        #expect(call.workspaceID == workspaceID)
        #expect(call.index == nil)
        #expect(call.before == (key == "before_workspace_id" ? targetID : nil))
        #expect(call.after == (key == "after_workspace_id" ? targetID : nil))
        #expect(call.dryRun == dryRun)
    }

    private func summary(id: UUID) -> ControlWorkspaceSummary {
        ControlWorkspaceSummary(
            id: id,
            title: "Workspace",
            customTitle: nil,
            customDescription: nil,
            isPinned: false,
            listeningPorts: [],
            remoteStatus: .object([:]),
            currentDirectory: nil,
            customColor: nil,
            latestConversationMessage: nil,
            latestSubmittedMessage: nil,
            latestSubmittedAt: nil
        )
    }

    /// The `not_found` payload must name the id that failed to resolve. Naming
    /// the subject tells the caller the one workspace that did resolve is the
    /// missing one.
    @Test(arguments: ["before_workspace_id", "after_workspace_id"])
    func unresolvedRelativeTargetNamesTheTarget(key: String) throws {
        let context = FakeWorkspaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()
        let result = coordinator.handle(ControlRequest(id: .int(1), method: "workspace.reorder", params: [
            "workspace_id": .string(workspaceID.uuidString),
            key: .string("workspace:999999"),
            "dry_run": .bool(true)
        ]))
        guard case .err(let code, _, .object(let data)) = result else {
            Issue.record("An unknown relative target must fail with a payload")
            return
        }
        #expect(code == "not_found")
        #expect(data["param"] == .string(key))
        #expect(data["workspace"] == .string("workspace:999999"))
        #expect(data["workspace_id"] != .string(workspaceID.uuidString))
    }

    /// A well-formed target id that no live workspace matches is still the
    /// target's failure, even though the planner reports one opaque `notFound`.
    @Test(arguments: ["before_workspace_id", "after_workspace_id"])
    func relativeTargetThatIsNotLiveNamesTheTarget(key: String) throws {
        let context = FakeWorkspaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()
        let missingID = UUID()
        context.listResolution = .resolved(
            windowID: nil,
            workspaces: [summary(id: workspaceID)],
            selectedIndex: 0
        )
        let result = coordinator.handle(ControlRequest(id: .int(1), method: "workspace.reorder", params: [
            "workspace_id": .string(workspaceID.uuidString),
            key: .string(missingID.uuidString),
            "dry_run": .bool(true)
        ]))
        guard case .err(let code, _, .object(let data)) = result else {
            Issue.record("A target that is not live must fail with a payload")
            return
        }
        #expect(code == "not_found")
        #expect(data["param"] == .string(key))
        #expect(data["workspace_id"] == .string(missingID.uuidString))
    }

    /// `hasNonNull` is true for values `uuid` can never read. A type error is
    /// not a missing workspace.
    @Test(arguments: [
        JSONValue.string(""), .string("   "), .int(5), .bool(true), .object([:]), .array([]),
    ])
    func malformedRelativeTargetIsInvalidParams(value: JSONValue) throws {
        for key in ["before_workspace_id", "after_workspace_id"] {
            let context = FakeWorkspaceControlCommandContext()
            let coordinator = ControlCommandCoordinator(context: context)
            let result = coordinator.handle(ControlRequest(id: .int(1), method: "workspace.reorder", params: [
                "workspace_id": .string(UUID().uuidString),
                key: value
            ]))
            guard case .err(let code, _, .object(let data)) = result else {
                Issue.record("A malformed \(key) must fail with a payload")
                return
            }
            #expect(code == "invalid_params")
            #expect(data["param"] == .string(key))
            #expect(context.reorderCall == nil)
        }
    }

    /// One target was specified; it was unreadable. "Specify exactly one
    /// target" sends the caller after the wrong param.
    @Test func unparsableIndexReportsAnInvalidIndex() throws {
        let context = FakeWorkspaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let result = coordinator.handle(ControlRequest(id: .int(1), method: "workspace.reorder", params: [
            "workspace_id": .string(UUID().uuidString),
            "index": .string("abc")
        ]))
        guard case .err(let code, let message, .object(let data)) = result else {
            Issue.record("An unreadable index must fail with a payload")
            return
        }
        #expect(code == "invalid_params")
        #expect(data["param"] == .string("index"))
        #expect(!message.contains("exactly one target"))
        #expect(context.reorderCall == nil)
    }

    /// The subject and the relative target are the same kind of reference, so
    /// an unresolvable ref reports the same way through either param.
    @Test func unresolvedSubjectRefReportsNotFoundEchoingTheRef() throws {
        let context = FakeWorkspaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let result = coordinator.handle(ControlRequest(id: .int(1), method: "workspace.reorder", params: [
            "workspace_id": .string("workspace:999999"),
            "index": .int(0)
        ]))
        guard case .err(let code, _, .object(let data)) = result else {
            Issue.record("An unresolvable subject ref must fail with a payload")
            return
        }
        #expect(code == "not_found")
        #expect(data["param"] == .string("workspace_id"))
        #expect(data["workspace"] == .string("workspace:999999"))
        #expect(context.reorderCall == nil)
    }

    /// A missing or unreadable `workspace_id` stays a request-shape error.
    @Test(arguments: [JSONValue.string(""), .int(7), .bool(true)])
    func malformedSubjectStaysInvalidParams(value: JSONValue) throws {
        let context = FakeWorkspaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let result = coordinator.handle(ControlRequest(id: .int(1), method: "workspace.reorder", params: [
            "workspace_id": value,
            "index": .int(0)
        ]))
        guard case .err(let code, _, _) = result else {
            Issue.record("A malformed workspace_id must fail")
            return
        }
        #expect(code == "invalid_params")
        #expect(context.reorderCall == nil)
    }

    /// A value neither `uuid(_:_:)` spelling can read — not a UUID, not a
    /// `kind:N` ref — is a typo, not a workspace that went away. Reporting it
    /// as `not_found` sends the caller looking for a workspace that never
    /// existed under that name. That includes a `kind:N` whose kind the
    /// registry never mints (`unknown:1`), and a known kind in the wrong case
    /// (`WORKSPACE:1`): refs are minted lowercase and looked up exactly.
    @Test(arguments: [
        "potato", "workspace", "workspace:", ":7", "workspace:abc", "7", "workspace 7",
        "unknown:1", "WORKSPACE:1",
    ])
    func unreadableSubjectIsInvalidParams(raw: String) throws {
        let context = FakeWorkspaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let result = coordinator.handle(ControlRequest(id: .int(1), method: "workspace.reorder", params: [
            "workspace_id": .string(raw),
            "index": .int(0),
            "dry_run": .bool(true)
        ]))
        guard case .err(let code, _, .object(let data)) = result else {
            Issue.record("An unreadable workspace_id must fail with a payload")
            return
        }
        #expect(code == "invalid_params")
        #expect(data["param"] == .string("workspace_id"))
        #expect(data["workspace"] == .string(raw))
        #expect(context.reorderCall == nil)
    }

    /// The same split on a relative target.
    @Test(arguments: ["before_workspace_id", "after_workspace_id"])
    func unreadableRelativeTargetIsInvalidParams(key: String) throws {
        let context = FakeWorkspaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let result = coordinator.handle(ControlRequest(id: .int(1), method: "workspace.reorder", params: [
            "workspace_id": .string(UUID().uuidString),
            key: .string("potato"),
            "dry_run": .bool(true)
        ]))
        guard case .err(let code, _, .object(let data)) = result else {
            Issue.record("An unreadable relative target must fail with a payload")
            return
        }
        #expect(code == "invalid_params")
        #expect(data["param"] == .string(key))
        #expect(data["workspace"] == .string("potato"))
        #expect(context.reorderCall == nil)
    }

    /// The other half of the split: a ref the registry once minted names a
    /// workspace that is gone, so it stays `not_found`.
    /// `TAB:4` is included because the registry lowercases the `tab:` alias.
    @Test(arguments: ["workspace:999999", "tab:4", "TAB:4", "pane:7", "workspace_group:2"])
    func staleRefSubjectStaysNotFound(raw: String) throws {
        let context = FakeWorkspaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let result = coordinator.handle(ControlRequest(id: .int(1), method: "workspace.reorder", params: [
            "workspace_id": .string(raw),
            "index": .int(0),
            "dry_run": .bool(true)
        ]))
        guard case .err(let code, _, .object(let data)) = result else {
            Issue.record("A stale ref must fail with a payload")
            return
        }
        #expect(code == "not_found")
        #expect(data["workspace"] == .string(raw))
        #expect(context.reorderCall == nil)
    }

    /// `workspace.reorder` and `workspace.reorder_many` must answer the same
    /// unresolvable value with the same code. They disagreed before this change,
    /// so a caller that fell back from one to the other saw the failure change
    /// class without the input changing. `workspace:999999` is the shape a
    /// closed workspace's ref takes once the registry forgets it.
    @Test(arguments: [
        ("potato", "invalid_params"),
        ("workspace:abc", "invalid_params"),
        ("unknown:1", "invalid_params"),
        ("", "invalid_params"),
        ("workspace:999999", "not_found"),
    ])
    func reorderAgreesWithReorderManyOnUnresolvableValues(raw: String, expected: String) throws {
        func code(of result: ControlCallResult?) -> String? {
            guard case .err(let code, _, _)? = result else { return nil }
            return code
        }
        // The coordinator holds its context weakly: an inline fake is freed
        // before `handle` runs, and `reorder` answers `unavailable`.
        let singleContext = FakeWorkspaceControlCommandContext()
        let manyContext = FakeWorkspaceControlCommandContext()
        let single = ControlCommandCoordinator(context: singleContext)
        let many = ControlCommandCoordinator(context: manyContext)
        let reorder = single.handle(ControlRequest(id: .int(1), method: "workspace.reorder", params: [
            "workspace_id": .string(raw), "index": .int(0), "dry_run": .bool(true)
        ]))
        let reorderMany = many.handle(ControlRequest(id: .int(1), method: "workspace.reorder_many", params: [
            "workspace_ids": .array([.string(raw)]), "dry_run": .bool(true)
        ]))
        #expect(code(of: reorder) == expected)
        #expect(code(of: reorderMany) == expected)
        withExtendedLifetime((singleContext, manyContext)) {}
    }

    /// A stale ref through `workspace.reorder_many` echoes the caller's value
    /// and keeps the id keys its UUID `not_found` reply carries, as `null`.
    @Test func reorderManyStaleRefEchoesTheRef() throws {
        let context = FakeWorkspaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let result = coordinator.handle(ControlRequest(id: .int(1), method: "workspace.reorder_many", params: [
            "workspace_ids": .array([.string("workspace:999999")]), "dry_run": .bool(true)
        ]))
        guard case .err(let code, _, .object(let data))? = result else {
            Issue.record("A stale ref must fail with a payload")
            return
        }
        #expect(code == "not_found")
        #expect(data["workspace"] == .string("workspace:999999"))
        #expect(data["workspace_id"] == .null)
        #expect(data["workspace_ref"] == .null)
    }

}
