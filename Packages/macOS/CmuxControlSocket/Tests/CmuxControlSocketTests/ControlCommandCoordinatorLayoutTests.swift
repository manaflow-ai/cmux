import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
private final class FakeLayoutControlCommandContext: ControlCommandContext {
    struct OpenInvocation: Equatable {
        let name: String
        let cwd: String?
        let templateParameters: [String: String]
        let focusRequested: Bool
    }

    var openResolution: ControlLayoutOpenResolution = .tabManagerUnavailable
    var openInvocation: OpenInvocation?

    func controlLayoutOpen(
        routing: ControlRoutingSelectors,
        name: String,
        cwd: String?,
        templateParameters: [String: String],
        focusRequested: Bool
    ) -> ControlLayoutOpenResolution {
        openInvocation = OpenInvocation(
            name: name,
            cwd: cwd,
            templateParameters: templateParameters,
            focusRequested: focusRequested
        )
        return openResolution
    }
}

@MainActor
@Suite("ControlCommandCoordinator layout domain")
struct ControlCommandCoordinatorLayoutTests {
    @Test func layoutOpenForwardsTemplateParameters() {
        let context = FakeLayoutControlCommandContext()
        let workspaceID = UUID()
        context.openResolution = .opened(workspaceID: workspaceID)
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "layout.open",
            params: [
                "name": .string("Ticket Dev"),
                "cwd": .string("/tmp/{{ticket}}"),
                "focus": .bool(false),
                "template_params": .object([
                    "ticket": .string("BERKS-87"),
                    "vitePort": .string("5174"),
                ]),
            ]
        ))

        #expect(context.openInvocation == .init(
            name: "Ticket Dev",
            cwd: "/tmp/{{ticket}}",
            templateParameters: ["ticket": "BERKS-87", "vitePort": "5174"],
            focusRequested: false
        ))
        #expect(result == .ok(.object([
            "workspace_id": .string(workspaceID.uuidString),
            "workspace_ref": .string("workspace:1"),
        ])))
    }

    @Test func layoutOpenRejectsNonStringTemplateParameterValue() {
        let context = FakeLayoutControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "layout.open",
            params: [
                "name": .string("Ticket Dev"),
                "template_params": .object([
                    "ticket": .string("BERKS-87"),
                    "vitePort": .int(5174),
                ]),
            ]
        ))

        #expect(result == .err(
            code: "invalid_params",
            message: "template_params must be an object with string values",
            data: nil
        ))
        #expect(context.openInvocation == nil)
    }

    @Test func layoutOpenReturnsStructuredMissingParameters() {
        let context = FakeLayoutControlCommandContext()
        context.openResolution = .missingParameters(["ticket", "vitePort"])
        let coordinator = ControlCommandCoordinator(context: context)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "layout.open",
            params: ["name": .string("Ticket Dev")]
        ))

        #expect(result == .err(
            code: "missing_parameters",
            message: "Missing workspace template parameters: ticket, vitePort",
            data: .object([
                "missing_parameters": .array([.string("ticket"), .string("vitePort")]),
            ])
        ))
    }
}
