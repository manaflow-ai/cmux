import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator command palette")
struct ControlCommandCoordinatorCommandPaletteTests {
    @Test func listReturnsLiveActionMetadataAndForwardsRouting() throws {
        let context = FakeCommandPaletteControlCommandContext()
        let windowID = UUID()
        let workspaceID = UUID()
        let panelID = UUID()
        let target = ControlCommandPaletteTarget(
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: panelID
        )
        let command = ControlCommandPaletteItem(
            id: "palette.demo",
            title: "Demo",
            subtitle: "Workspace",
            shortcutHint: "⌘D",
            keywords: ["sample"],
            dismissOnRun: true,
            arguments: [ControlCommandPaletteArgument(
                name: "path",
                type: "path",
                required: true,
                allowsEmpty: false
            )]
        )
        context.listResolution = .listed(target: target, commands: [command])
        let coordinator = ControlCommandCoordinator(context: context)

        let result = try #require(coordinator.handle(request(
            method: "palette.list",
            params: ["workspace_id": .string(workspaceID.uuidString)]
        )))

        #expect(context.listRouting?.workspaceID == workspaceID)
        #expect(context.listRouting?.hasWorkspaceIDParam == true)
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected palette.list payload")
            return
        }
        #expect(payload["window_id"] == .string(windowID.uuidString))
        #expect(payload["window_ref"] == .string("window:1"))
        #expect(payload["workspace_id"] == .string(workspaceID.uuidString))
        #expect(payload["workspace_ref"] == .string("workspace:1"))
        #expect(payload["surface_id"] == .string(panelID.uuidString))
        #expect(payload["surface_ref"] == .string("surface:1"))
        #expect(payload["target"] == .object([
            "window_id": .string(windowID.uuidString),
            "workspace_id": .string(workspaceID.uuidString),
            "panel_id": .string(panelID.uuidString),
        ]))
        #expect(payload["count"] == .int(1))
        #expect(payload["commands"] == .array([.object([
            "id": .string("palette.demo"),
            "title": .string("Demo"),
            "subtitle": .string("Workspace"),
            "shortcut_hint": .string("⌘D"),
            "keywords": .array([.string("sample")]),
            "dismiss_on_run": .bool(true),
            "arguments": .array([.object([
                "name": .string("path"),
                "type": .string("path"),
                "required": .bool(true),
                "allows_empty": .bool(false),
            ])]),
        ])]))
    }

    @Test func listPreservesUnresolvedSelectorPresenceForAppRouting() throws {
        let context = FakeCommandPaletteControlCommandContext()
        context.listResolution = .listed(
            target: ControlCommandPaletteTarget(
                windowID: UUID(),
                workspaceID: nil,
                panelID: nil
            ),
            commands: []
        )
        let coordinator = ControlCommandCoordinator(context: context)

        _ = try #require(coordinator.handle(request(
            method: "palette.list",
            params: [
                "group_id": .string("workspace_group:missing"),
                "workspace_id": .string("workspace:missing"),
                "surface_id": .string("surface:missing"),
                "pane_id": .string("pane:missing"),
            ]
        )))

        let routing = try #require(context.listRouting)
        #expect(routing.hasGroupIDParam)
        #expect(routing.groupID == nil)
        #expect(routing.hasWorkspaceIDParam)
        #expect(routing.workspaceID == nil)
        #expect(routing.hasSurfaceIDParam)
        #expect(routing.surfaceID == nil)
        #expect(routing.hasPaneIDParam)
        #expect(routing.paneID == nil)
    }

    @Test func routingSelectorInitializerInfersPresenceForExistingCallers() {
        let groupID = UUID()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let paneID = UUID()
        let selected = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: groupID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            paneID: paneID
        )
        #expect(selected.hasGroupIDParam)
        #expect(selected.hasWorkspaceIDParam)
        #expect(selected.hasSurfaceIDParam)
        #expect(selected.hasPaneIDParam)

        let omitted = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: nil,
            surfaceID: nil,
            paneID: nil
        )
        #expect(!omitted.hasGroupIDParam)
        #expect(!omitted.hasWorkspaceIDParam)
        #expect(!omitted.hasSurfaceIDParam)
        #expect(!omitted.hasPaneIDParam)
    }

    @Test func runInvokesTheRequestedLiveAction() throws {
        let context = FakeCommandPaletteControlCommandContext()
        let windowID = UUID()
        let command = ControlCommandPaletteItem(
            id: "palette.demo",
            title: "Demo",
            subtitle: "Workspace",
            shortcutHint: nil,
            keywords: [],
            dismissOnRun: false
        )
        context.runResolution = .completed(windowID: windowID, command: command)
        let coordinator = ControlCommandCoordinator(context: context)

        let result = try #require(coordinator.handle(request(
            method: "palette.run",
            params: [
                "command_id": .string("palette.demo"),
                "arguments": .object(["name": .string("Renamed")]),
                "cwd": .string("/tmp/project"),
            ]
        )))

        #expect(context.runCall?.commandID == "palette.demo")
        #expect(context.runCall?.arguments == ["name": "Renamed"])
        #expect(context.runCall?.workingDirectory == "/tmp/project")
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected palette.run payload")
            return
        }
        #expect(payload["window_id"] == .string(windowID.uuidString))
        #expect(payload["window_ref"] == .string("window:1"))
        guard case .object(let encodedCommand)? = payload["command"] else {
            Issue.record("expected encoded command")
            return
        }
        #expect(encodedCommand["id"] == .string("palette.demo"))
        #expect(encodedCommand["dismiss_on_run"] == .bool(false))
        #expect(payload["status"] == .string("completed"))
    }

    @Test func runEchoesTheListedTargetInsteadOfUsingCurrentRoutingSelectors() throws {
        let context = FakeCommandPaletteControlCommandContext()
        let windowID = UUID()
        let workspaceID = UUID()
        let panelID = UUID()
        let command = testCommand()
        context.runResolution = .completed(windowID: windowID, command: command)
        let coordinator = ControlCommandCoordinator(context: context)

        _ = try #require(coordinator.handle(request(
            method: "palette.run",
            params: [
                "command_id": .string(command.id),
                // These legacy selectors deliberately point elsewhere. An
                // echoed target is one immutable list-time identity and wins.
                "window_id": .string(UUID().uuidString),
                "workspace_id": .string(UUID().uuidString),
                "surface_id": .string(UUID().uuidString),
                "target": .object([
                    "window_id": .string(windowID.uuidString),
                    "workspace_id": .string(workspaceID.uuidString),
                    "panel_id": .string(panelID.uuidString),
                ]),
            ]
        )))

        #expect(context.runTarget == ControlCommandPaletteTarget(
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: panelID
        ))
        #expect(context.runCall == nil)
    }

    @Test func runRejectsMalformedImmutableTargetWithoutFallingBack() throws {
        let context = FakeCommandPaletteControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = try #require(coordinator.handle(request(
            method: "palette.run",
            params: [
                "command_id": .string("palette.demo"),
                "window_id": .string(UUID().uuidString),
                "target": .object([
                    "window_id": .string(UUID().uuidString),
                    "workspace_id": .null,
                    // A panel without a workspace cannot be an exact target.
                    "panel_id": .string(UUID().uuidString),
                ]),
            ]
        )))

        guard case .err(let code, let message, _) = result else {
            Issue.record("expected invalid-target error")
            return
        }
        #expect(code == "invalid_params")
        #expect(message == context.paletteStrings.invalidTarget)
        #expect(context.runCall == nil)
    }

    @Test func runReportsAStaleImmutableTargetSeparatelyFromAMissingWindow() throws {
        let context = FakeCommandPaletteControlCommandContext()
        context.runResolution = .targetUnavailable
        let coordinator = ControlCommandCoordinator(context: context)
        let target = ControlCommandPaletteTarget(
            windowID: UUID(),
            workspaceID: UUID(),
            panelID: UUID()
        )

        let result = try #require(coordinator.handle(request(
            method: "palette.run",
            params: [
                "command_id": .string("palette.demo"),
                "target": .object([
                    "window_id": .string(target.windowID.uuidString),
                    "workspace_id": .string(target.workspaceID!.uuidString),
                    "panel_id": .string(target.panelID!.uuidString),
                ]),
            ]
        )))

        guard case .err(let code, let message, let data) = result else {
            Issue.record("expected stale-target error")
            return
        }
        #expect(code == "target_unavailable")
        #expect(message == context.paletteStrings.targetUnavailable)
        #expect(data == .object([
            "window_id": .string(target.windowID.uuidString),
            "workspace_id": .string(target.workspaceID!.uuidString),
            "panel_id": .string(target.panelID!.uuidString),
        ]))
    }

    @Test func runDistinguishesQueuedAndPresentedActions() throws {
        let context = FakeCommandPaletteControlCommandContext()
        let windowID = UUID()
        let command = testCommand()
        let coordinator = ControlCommandCoordinator(context: context)
        let cases: [(ControlCommandPaletteRunResolution, String)] = [
            (.queued(windowID: windowID, command: command), "queued"),
            (.presented(windowID: windowID, command: command), "presented"),
        ]

        for (resolution, expectedStatus) in cases {
            context.runResolution = resolution
            let result = try #require(coordinator.handle(request(
                method: "palette.run",
                params: ["command_id": .string(command.id)]
            )))
            guard case .ok(.object(let payload)) = result else {
                Issue.record("expected successful palette.run payload")
                continue
            }
            #expect(payload["status"] == .string(expectedStatus))
        }
    }

    @Test func runMapsAllTypedValidationAndFailureResults() throws {
        let context = FakeCommandPaletteControlCommandContext()
        let windowID = UUID()
        let command = testCommand()
        let coordinator = ControlCommandCoordinator(context: context)

        context.runResolution = .invalidArguments(
            windowID: windowID,
            command: command,
            names: ["extra"]
        )
        let unknown = try #require(coordinator.handle(request(
            method: "palette.run",
            params: ["command_id": .string(command.id)]
        )))
        guard case .err(let unknownCode, let unknownMessage, .object(let unknownData)?) = unknown else {
            Issue.record("expected unknown-arguments error")
            return
        }
        #expect(unknownCode == "invalid_params")
        #expect(unknownMessage == "unknown: extra")
        #expect(unknownData["unknown_arguments"] == .array([.string("extra")]))

        context.runResolution = .invalidArgumentValues(
            windowID: windowID,
            command: command,
            names: ["overwrite"]
        )
        let invalid = try #require(coordinator.handle(request(
            method: "palette.run",
            params: ["command_id": .string(command.id)]
        )))
        guard case .err(let invalidCode, let invalidMessage, .object(let invalidData)?) = invalid else {
            Issue.record("expected invalid-value error")
            return
        }
        #expect(invalidCode == "invalid_params")
        #expect(invalidMessage == "invalid: overwrite")
        #expect(invalidData["invalid_arguments"] == .array([.string("overwrite")]))

        context.runResolution = .failed(
            windowID: windowID,
            command: command,
            code: "action_failed",
            message: "Action failed to start"
        )
        let failed = try #require(coordinator.handle(request(
            method: "palette.run",
            params: ["command_id": .string(command.id)]
        )))
        guard case .err(let failedCode, let failedMessage, .object(let failedData)?) = failed else {
            Issue.record("expected action failure")
            return
        }
        #expect(failedCode == "action_failed")
        #expect(failedMessage == "Action failed to start")
        #expect(failedData["window_id"] == .string(windowID.uuidString))
    }

    @Test func runRejectsMissingAndUnavailableActionIDs() throws {
        let context = FakeCommandPaletteControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let missing = try #require(coordinator.handle(request(method: "palette.run")))
        guard case .err(let missingCode, let missingMessage, _) = missing else {
            Issue.record("expected missing-id error")
            return
        }
        #expect(missingCode == "invalid_params")
        #expect(missingMessage == context.paletteStrings.missingCommandID)
        #expect(context.runCall == nil)

        context.runResolution = .commandNotFound
        let unavailable = try #require(coordinator.handle(request(
            method: "palette.run",
            params: ["command_id": .string("palette.hidden")]
        )))
        guard case .err(let unavailableCode, let unavailableMessage, let data) = unavailable else {
            Issue.record("expected unavailable-action error")
            return
        }
        #expect(unavailableCode == "not_found")
        #expect(unavailableMessage == context.paletteStrings.commandNotFound)
        #expect(data == .object(["command_id": .string("palette.hidden")]))
    }

    @Test func runReturnsTheStaticSchemaWhenRequiredArgumentsAreMissing() throws {
        let context = FakeCommandPaletteControlCommandContext()
        let windowID = UUID()
        let argument = ControlCommandPaletteArgument(
            name: "name",
            type: "string",
            required: true,
            allowsEmpty: true
        )
        let command = ControlCommandPaletteItem(
            id: "palette.renameWorkspace",
            title: "Rename Workspace",
            subtitle: "Workspace",
            shortcutHint: nil,
            keywords: [],
            dismissOnRun: false,
            arguments: [argument]
        )
        context.runResolution = .requiresArguments(
            windowID: windowID,
            command: command,
            arguments: [argument]
        )
        let coordinator = ControlCommandCoordinator(context: context)

        let result = try #require(coordinator.handle(request(
            method: "palette.run",
            params: ["command_id": .string(command.id)]
        )))

        guard case .err(let code, let message, .object(let data)?) = result else {
            Issue.record("expected missing-arguments error")
            return
        }
        #expect(code == "invalid_params")
        #expect(message == "missing: name")
        #expect(data["required_arguments"] == .array([.object([
            "name": .string("name"),
            "type": .string("string"),
            "required": .bool(true),
            "allows_empty": .bool(true),
        ])]))
    }

    @Test func runRejectsNonStringArgumentValuesBeforeDispatch() throws {
        let context = FakeCommandPaletteControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = try #require(coordinator.handle(request(
            method: "palette.run",
            params: [
                "command_id": .string("palette.demo"),
                "arguments": .object(["count": .int(2)]),
            ]
        )))

        guard case .err(let code, let message, _) = result else {
            Issue.record("expected invalid-arguments error")
            return
        }
        #expect(code == "invalid_params")
        #expect(message == context.paletteStrings.argumentsMustBeStringObject)
        #expect(context.runCall == nil)
    }

    private func request(
        method: String,
        params: [String: JSONValue] = [:]
    ) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }

    private func testCommand() -> ControlCommandPaletteItem {
        ControlCommandPaletteItem(
            id: "palette.demo",
            title: "Demo",
            subtitle: "Workspace",
            shortcutHint: nil,
            keywords: [],
            dismissOnRun: true
        )
    }
}
