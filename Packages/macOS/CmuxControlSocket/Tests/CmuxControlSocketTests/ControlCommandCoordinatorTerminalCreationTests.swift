import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator terminal creation")
struct ControlCommandCoordinatorTerminalCreationTests {
    private func capturedCreationInputs(
        method: String,
        initialCommand: JSONValue? = nil,
        initialInput: JSONValue? = nil,
        type: JSONValue? = nil
    ) -> (wasCaptured: Bool, initialCommand: String?, initialInput: String?) {
        let context = FakeSurfaceControlCommandContext()
        context.paneCreateResolution = .createFailed
        context.splitResolution = .createFailed
        context.createResolution = .createFailed
        let coordinator = ControlCommandCoordinator(context: context)
        var params: [String: JSONValue] = [:]
        if method != "surface.create" {
            params["direction"] = .string("right")
        }
        if let initialCommand {
            params["initial_command"] = initialCommand
        }
        if let initialInput {
            params["initial_input"] = initialInput
        }
        if let type {
            params["type"] = type
        }

        _ = coordinator.handle(ControlRequest(
            id: .int(1),
            method: method,
            params: params
        ))

        switch method {
        case "surface.split":
            return (
                context.splitInputs != nil,
                context.splitInputs?.initialCommand,
                context.splitInputs?.initialInput
            )
        case "pane.create":
            return (
                context.paneCreateInputs != nil,
                context.paneCreateInputs?.initialCommand,
                context.paneCreateInputs?.initialInput
            )
        case "surface.create":
            return (
                context.createInputs != nil,
                context.createInputs?.initialCommand,
                context.createInputs?.initialInput
            )
        default:
            Issue.record("unexpected creation method \(method)")
            return (false, nil, nil)
        }
    }

    @Test(
        "terminal creation RPCs preserve initial-command quoting",
        arguments: ["surface.split", "pane.create", "surface.create"]
    )
    func terminalCreationPreservesInitialCommandQuoting(method: String) {
        let command = #"printf '%s\n' "spaces 'single' \"double\" $HOME $(printf nested) \\tail 日本語"#
        let capture = capturedCreationInputs(
            method: method,
            initialCommand: .string(command)
        )

        #expect(capture.wasCaptured)
        #expect(capture.initialCommand == command)
    }

    @Test(
        "terminal creation RPCs preserve plain-shell behavior when initial_command is omitted",
        arguments: ["surface.split", "pane.create", "surface.create"]
    )
    func terminalCreationOmitsInitialCommand(method: String) {
        let capture = capturedCreationInputs(method: method)

        #expect(capture.wasCaptured)
        #expect(capture.initialCommand == nil)
    }

    @Test(
        "terminal creation RPCs preserve initial-input bytes",
        arguments: ["surface.split", "pane.create", "surface.create"]
    )
    func terminalCreationPreservesInitialInput(method: String) {
        let input = " printf '  preserved  '\t\r"
        let capture = capturedCreationInputs(
            method: method,
            initialInput: .string(input)
        )

        #expect(capture.wasCaptured)
        #expect(capture.initialCommand == nil)
        #expect(capture.initialInput == input)
    }

    @Test(
        "terminal creation RPCs treat null type as omitted",
        arguments: ["surface.split", "pane.create", "surface.create"]
    )
    func terminalCreationAllowsNullType(method: String) {
        let input = "echo null type\r"
        let capture = capturedCreationInputs(
            method: method,
            initialInput: .string(input),
            type: .null
        )

        #expect(capture.wasCaptured)
        #expect(capture.initialCommand == nil)
        #expect(capture.initialInput == input)
    }

    @Test(
        "terminal creation RPCs omit blank initial_input",
        arguments: ["surface.split", "pane.create", "surface.create"]
    )
    func terminalCreationOmitsBlankInitialInput(method: String) {
        let capture = capturedCreationInputs(
            method: method,
            initialInput: .string(" \n\t ")
        )

        #expect(capture.wasCaptured)
        #expect(capture.initialInput == nil)
    }

    @Test(
        "terminal creation RPCs reject initial input for non-terminal types before creation",
        arguments: [
            ("surface.split", "browser"),
            ("surface.split", "simulator"),
            ("surface.split", "agent-session"),
            ("pane.create", "browser"),
            ("pane.create", "simulator"),
            ("pane.create", "agent-session"),
            ("surface.create", "browser"),
            ("surface.create", "simulator"),
            ("surface.create", "agent-session"),
        ] as [(String, String)]
    )
    func terminalCreationRejectsNonTerminalInitialInput(
        method: String,
        type: String
    ) {
        let context = FakeSurfaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        var params: [String: JSONValue] = [
            "type": .string(type),
            "initial_input": .string("echo should-not-run\r"),
        ]
        if method != "surface.create" {
            params["direction"] = .string("right")
        }

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: method,
            params: params
        ))

        #expect(result == .err(
            code: "invalid_params",
            message: "app-localized terminal creation type error",
            data: .object(["type": .string(type)])
        ))
        #expect(context.paneCreateInputs == nil)
        #expect(context.splitInputs == nil)
        #expect(context.createInputs == nil)
    }

    @Test(
        "terminal creation RPCs reject non-string types before creation",
        arguments: [
            ("surface.split", .bool(true)),
            ("surface.split", .int(1)),
            ("surface.split", .object(["kind": .string("terminal")])),
            ("pane.create", .bool(true)),
            ("pane.create", .int(1)),
            ("pane.create", .object(["kind": .string("terminal")])),
            ("surface.create", .bool(true)),
            ("surface.create", .int(1)),
            ("surface.create", .object(["kind": .string("terminal")])),
        ] as [(String, JSONValue)]
    )
    func terminalCreationRejectsNonStringType(
        method: String,
        type: JSONValue
    ) {
        let context = FakeSurfaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        var params: [String: JSONValue] = [
            "type": type,
            "initial_input": .string("echo should-not-run\r"),
        ]
        if method != "surface.create" {
            params["direction"] = .string("right")
        }

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: method,
            params: params
        ))

        #expect(result == .err(
            code: "invalid_params",
            message: "app-localized terminal creation type error",
            data: .object(["type": type])
        ))
        #expect(context.paneCreateInputs == nil)
        #expect(context.splitInputs == nil)
        #expect(context.createInputs == nil)
    }
}
