internal import Foundation

extension ControlCommandCoordinator {
    nonisolated func simulatorType(
        _ params: [String: JSONValue],
        context: (any ControlCommandContext)?,
        completionTimeout: TimeInterval? = nil
    ) -> ControlCallResult {
        guard case let .string(text)? = params["text"] else {
            return simulatorInvalidParameters(diagnostic: "text is required")
        }
        guard let context else {
            return simulatorNoActiveWindow()
        }
        guard simulatorOperationAdmissionGate.acquire() else {
            return simulatorAdmissionFailure()
        }
        defer { simulatorOperationAdmissionGate.release() }
        let outcome: SimulatorTypeHopOutcome = context.controlResolveOnMain { seam in
            let resolution = seam.controlSimulatorBeginType(
                routing: self.routingSelectors(params),
                text: text
            )
            let surfaceRef: JSONValue?
            if case let .started(surfaceID, _, _, _) = resolution {
                surfaceRef = self.ref(.surface, surfaceID)
            } else {
                surfaceRef = nil
            }
            return SimulatorTypeHopOutcome(resolution: resolution, surfaceRef: surfaceRef)
        }
        switch outcome.resolution {
        case let .started(surfaceID, characterCount, contractTimeout, receipt):
            switch receipt.wait(timeout: completionTimeout ?? contractTimeout) {
            case .succeeded:
                return .ok(.object([
                    "surface_id": .string(surfaceID.uuidString),
                    "surface_ref": outcome.surfaceRef ?? .null,
                    "character_count": .int(Int64(characterCount)),
                ]))
            case .failed:
                return .err(
                    code: "input_failed",
                    message: String(
                        localized: "cli.simulator.error.inputFailed",
                        defaultValue: "Simulator input transmission failed"
                    ),
                    data: .object(["surface_id": .string(surfaceID.uuidString)])
                )
            case nil:
                return .err(
                    code: "timeout",
                    message: String(
                        localized: "cli.simulator.error.inputTimeout",
                        defaultValue: "Simulator input transmission did not complete before the deadline"
                    ),
                    data: .object(["surface_id": .string(surfaceID.uuidString)])
                )
            }
        case let .failed(failure):
            return simulatorTargetFailure(failure)
        case .emptyText:
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "cli.simulator.error.textEmpty",
                    defaultValue: "Text must not be empty"
                ),
                data: nil
            )
        case let .textTooLong(maximum):
            return .err(
                code: "invalid_params",
                message: String.localizedStringWithFormat(
                    String(
                        localized: "cli.simulator.error.textTooLong",
                        defaultValue: "Text exceeds the %lld-byte UTF-8 limit"
                    ),
                    maximum
                ),
                data: .object(["maximum_utf8_bytes": .int(Int64(maximum))])
            )
        case let .unsupportedCharacter(index, value):
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "cli.simulator.error.unsupportedText",
                    defaultValue: "Text contains a character unsupported by Simulator input"
                ),
                data: .object([
                    "scalar_index": .int(Int64(index)),
                    "scalar_value": .int(Int64(value)),
                ])
            )
        case .inputUnavailable:
            return .err(
                code: "unavailable",
                message: String(
                    localized: "cli.simulator.error.keyboardUnavailable",
                    defaultValue: "Simulator keyboard input is unavailable"
                ),
                data: nil
            )
        case .deliveryUnavailable:
            return .err(
                code: "unavailable",
                message: String(
                    localized: "cli.simulator.error.transmissionUnavailable",
                    defaultValue: "Simulator input transmission is unavailable"
                ),
                data: nil
            )
        }
    }

    nonisolated func simulatorTargetFailure(
        _ failure: ControlSimulatorTargetFailure
    ) -> ControlCallResult {
        switch failure {
        case .tabManagerUnavailable:
            return simulatorNoActiveWindow()
        case .workspaceNotFound:
            return .err(code: "not_found", message: String(
                localized: "cli.simulator.error.workspaceNotFound",
                defaultValue: "Workspace not found"
            ), data: nil)
        case .remoteWorkspace:
            return .err(code: "unsupported", message: String(
                localized: "cli.simulator.error.remoteWorkspace",
                defaultValue: "Simulator control is unavailable in remote workspaces"
            ), data: nil)
        case let .surfaceNotFound(surfaceID):
            return .err(
                code: "not_found",
                message: String(
                    localized: "cli.simulator.error.surfaceNotFound",
                    defaultValue: "Surface not found"
                ),
                data: surfaceID.map { .object(["surface_id": .string($0.uuidString)]) }
            )
        case let .surfaceNotSimulator(surfaceID):
            return .err(
                code: "invalid_target",
                message: String(
                    localized: "cli.simulator.error.surfaceNotSimulator",
                    defaultValue: "The target surface is not a Simulator"
                ),
                data: .object(["surface_id": .string(surfaceID.uuidString)])
            )
        case .simulatorNotFound:
            return .err(code: "not_found", message: String(
                localized: "cli.simulator.error.simulatorNotFound",
                defaultValue: "No Simulator surface was found"
            ), data: nil)
        case let .ambiguousSimulatorSurfaces(count):
            return .err(
                code: "ambiguous_target",
                message: String(
                    localized: "cli.simulator.error.ambiguousSurface",
                    defaultValue: "Multiple Simulator surfaces were found; pass surface_id"
                ),
                data: .object(["count": .int(Int64(count))])
            )
        }
    }
}

private struct SimulatorTypeHopOutcome: Sendable {
    let resolution: ControlSimulatorTypeStartResolution
    let surfaceRef: JSONValue?
}
