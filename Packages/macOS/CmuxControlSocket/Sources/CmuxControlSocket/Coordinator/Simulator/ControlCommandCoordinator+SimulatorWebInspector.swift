internal import Foundation

extension ControlCommandCoordinator {
    nonisolated func simulatorWebInspector(
        _ request: ControlRequest,
        context: (any ControlCommandContext)?
    ) -> ControlCallResult? {
        switch request.method {
        case "simulator.web_inspector.targets":
            return runWebInspector(request.params, context: context) { seam, routing in
                seam.controlSimulatorBeginWebInspectorTargets(routing: routing)
            }
        case "simulator.web_inspector.attach":
            guard let targetID = string(request.params, "target_id") else {
                return simulatorInvalidParameters(diagnostic: "target_id is required")
            }
            return runWebInspector(request.params, context: context) { seam, routing in
                seam.controlSimulatorBeginWebInspectorAttach(routing: routing, targetID: targetID)
            }
        case "simulator.web_inspector.send":
            guard case let .string(json)? = request.params["json"], !json.isEmpty else {
                return simulatorInvalidParameters(diagnostic: "json is required")
            }
            guard json.utf8.count <= controlSimulatorMaximumWebInspectorJSONByteCount else {
                return simulatorInvalidParameters(
                    diagnostic: "json exceeds the 1048576-byte UTF-8 limit"
                )
            }
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  case let .object(dictionary)? = JSONValue(foundationObject: object),
                  simulatorWebInspectorMessageID(dictionary["id"]) else {
                return simulatorInvalidParameters(
                    diagnostic: "json must be an object with a string or numeric id"
                )
            }
            return runWebInspector(request.params, context: context) { seam, routing in
                seam.controlSimulatorBeginWebInspectorSend(routing: routing, json: json)
            }
        case "simulator.web_inspector.highlight":
            guard case let .bool(enabled)? = request.params["enabled"] else {
                return simulatorInvalidParameters(diagnostic: "enabled must be a boolean")
            }
            return runWebInspector(request.params, context: context) { seam, routing in
                seam.controlSimulatorBeginWebInspectorHighlight(routing: routing, enabled: enabled)
            }
        case "simulator.web_inspector.release":
            return runWebInspector(request.params, context: context) { seam, routing in
                seam.controlSimulatorBeginWebInspectorRelease(routing: routing)
            }
        default:
            return nil
        }
    }

    private nonisolated func simulatorWebInspectorMessageID(_ value: JSONValue?) -> Bool {
        switch value {
        case let .string(value)?:
            value.utf8.count <= 1_024
        case let .int(value)?:
            abs(Double(value)) <= 9_007_199_254_740_991
        case let .double(value)?:
            value.isFinite
                && value.rounded() == value
                && abs(value) <= 9_007_199_254_740_991
        default: false
        }
    }

    private nonisolated func runWebInspector(
        _ params: [String: JSONValue],
        context: (any ControlCommandContext)?,
        start: @MainActor (
            any ControlCommandContext,
            ControlRoutingSelectors
        ) -> ControlSimulatorWebInspectorStartResolution
    ) -> ControlCallResult {
        guard let context else {
            return simulatorNoActiveWindow()
        }
        guard simulatorOperationAdmissionGate.acquire() else {
            return simulatorAdmissionFailure()
        }
        defer { simulatorOperationAdmissionGate.release() }
        let outcome: SimulatorWebInspectorHopOutcome = context.controlResolveOnMain { seam in
            let resolution = start(seam, self.routingSelectors(params))
            let surfaceRef: JSONValue?
            if case let .started(surfaceID, _, _) = resolution {
                surfaceRef = self.ref(.surface, surfaceID)
            } else {
                surfaceRef = nil
            }
            return SimulatorWebInspectorHopOutcome(resolution: resolution, surfaceRef: surfaceRef)
        }
        switch outcome.resolution {
        case let .started(surfaceID, timeout, receipt):
            guard let completion = receipt.wait(timeout: timeout) else {
                return .err(
                    code: "timeout",
                    message: String(
                        localized: "cli.simulator.error.webInspectorTimeout",
                        defaultValue: "The Web Inspector operation did not complete before the deadline"
                    ),
                    data: .object(["surface_id": .string(surfaceID.uuidString)])
                )
            }
            return webInspectorCompletionResult(
                completion,
                surfaceID: surfaceID,
                surfaceRef: outcome.surfaceRef ?? .null
            )
        case let .failed(failure):
            return simulatorTargetFailure(failure)
        case .unavailable:
            return .err(code: "unavailable", message: String(
                localized: "cli.simulator.error.webInspectorUnavailable",
                defaultValue: "Native Web Inspector is unavailable"
            ), data: nil)
        case let .targetNotFound(targetID):
            return .err(code: "not_found", message: String(
                localized: "cli.simulator.error.webInspectorTargetNotFound",
                defaultValue: "The Web Inspector target was not found"
            ), data: .object([
                "target_id": .string(targetID),
            ]))
        case .sessionDetached:
            return .err(code: "invalid_state", message: String(
                localized: "cli.simulator.error.webInspectorDetached",
                defaultValue: "No Web Inspector target is attached"
            ), data: nil)
        }
    }

    private nonisolated func webInspectorCompletionResult(
        _ completion: ControlSimulatorWebInspectorCompletion,
        surfaceID: UUID,
        surfaceRef: JSONValue
    ) -> ControlCallResult {
        let base: [String: JSONValue] = [
            "surface_id": .string(surfaceID.uuidString),
            "surface_ref": surfaceRef,
        ]
        switch completion {
        case let .targets(snapshot):
            return .ok(webInspectorSnapshotPayload(snapshot, surfaceRef: surfaceRef))
        case let .session(session):
            return .ok(.object(base.merging([
                "session": webInspectorSessionPayload(session),
            ], uniquingKeysWith: { _, new in new })))
        case let .highlighted(enabled):
            return .ok(.object(base.merging([
                "highlighted": .bool(enabled),
            ], uniquingKeysWith: { _, new in new })))
        case .released:
            return .ok(.object(base.merging([
                "released": .bool(true),
            ], uniquingKeysWith: { _, new in new })))
        case let .response(json, truncated):
            return .ok(.object(base.merging([
                "response_json": .string(json),
                "truncated": .bool(truncated),
            ], uniquingKeysWith: { _, new in new })))
        case let .failed(code, message):
            return simulatorSafeFailure(
                code: code,
                diagnostic: message,
                data: ["surface_id": .string(surfaceID.uuidString)]
            )
        }
    }

    private nonisolated func webInspectorSnapshotPayload(
        _ snapshot: ControlSimulatorWebInspectorSnapshot,
        surfaceRef: JSONValue
    ) -> JSONValue {
        .object([
            "surface_id": .string(snapshot.surfaceID.uuidString),
            "surface_ref": surfaceRef,
            "session": webInspectorSessionPayload(snapshot.session),
            "highlighted": .bool(snapshot.isHighlighted),
            "targets": .array(snapshot.targets.map { target in
                .object([
                    "id": .string(target.id),
                    "application_identifier": .string(target.applicationIdentifier),
                    "page_identifier": .int(Int64(clamping: target.pageIdentifier)),
                    "title": .string(target.title),
                    "url": .string(target.url),
                    "type": .string(target.type),
                    "application_name": .string(target.applicationName),
                    "bundle_identifier": orNull(target.bundleIdentifier),
                    "in_use": .bool(target.isInUse),
                ])
            }),
        ])
    }

    private nonisolated func webInspectorSessionPayload(
        _ session: ControlSimulatorWebInspectorSessionSnapshot
    ) -> JSONValue {
        switch session {
        case .detached:
            return .object(["state": .string("detached")])
        case let .attached(sessionID, targetID):
            return .object([
                "state": .string("attached"),
                "session_id": .string(sessionID.uuidString),
                "target_id": .string(targetID),
            ])
        }
    }
}

private struct SimulatorWebInspectorHopOutcome: Sendable {
    let resolution: ControlSimulatorWebInspectorStartResolution
    let surfaceRef: JSONValue?
}
