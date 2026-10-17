import Foundation

public actor PhoneSession {
    public nonisolated let id: String

    private let driver: any PhoneDriver
    private var currentSequence: UInt64 = 0
    private var closed = false

    public init(id: String = UUID().uuidString.lowercased(), driver: any PhoneDriver) {
        self.id = id
        self.driver = driver
    }

    public func handle(_ request: PhoneEnvelope) async -> [PhoneEnvelope] {
        guard !closed else {
            return [.failure(
                id: request.id,
                sessionID: id,
                error: PhoneError(code: "session_closed", message: "session is closed")
            )]
        }
        guard request.type == .request, let requestID = request.id, let method = request.method else {
            return [.failure(
                id: request.id,
                sessionID: id,
                error: PhoneError(code: "invalid_request", message: "a request needs id and method")
            )]
        }
        guard request.sessionID == nil || request.sessionID == id else {
            return [.failure(
                id: requestID,
                sessionID: id,
                error: PhoneError(code: "session_mismatch", message: "request targets another session")
            )]
        }

        do {
            switch method {
            case "screen.snapshot":
                let frame = try await driver.snapshot()
                currentSequence = frame.sequence
                return [.response(id: requestID, sessionID: id, result: try PhoneJSONValue(frame))]

            case "ui.snapshot":
                guard let tree = try await driver.accessibilityTree() else {
                    throw PhoneError(
                        code: "capability_unavailable",
                        message: "this source does not expose an accessibility tree"
                    )
                }
                return [.response(id: requestID, sessionID: id, result: try PhoneJSONValue(tree))]

            case "screen.subscribe":
                let frame = try await driver.snapshot()
                currentSequence = frame.sequence
                let result = PhoneJSONValue.object([
                    "mode": .string("pull"),
                    "sequence": .number(Double(frame.sequence)),
                    "detail": .string("poll screen.snapshot or use a native stream adapter"),
                ])
                return [.response(id: requestID, sessionID: id, result: result)]

            case "session.close":
                closed = true
                return [.response(id: requestID, sessionID: id, result: .object(["closed": .boolean(true)]))]

            case "action.tap", "action.swipe", "action.long_press", "action.type", "action.press":
                let action = try decodeAction(method: method, params: request.params)
                if let expected = action.screenSequence, expected != currentSequence {
                    throw PhoneError(
                        code: "stale_screen",
                        message: "action references screen sequence \(expected), current is \(currentSequence)",
                        retryable: true,
                        details: .object(["current_seq": .number(Double(currentSequence))])
                    )
                }
                let receipt = try await driver.perform(action)
                currentSequence = receipt.screenSequence
                let response = PhoneEnvelope.response(
                    id: requestID,
                    sessionID: id,
                    result: try PhoneJSONValue(receipt)
                )
                let event = PhoneEnvelope.event(
                    method: "ui.changed",
                    sessionID: id,
                    sequence: receipt.screenSequence,
                    result: .object([
                        "action_id": .string(receipt.actionID),
                        "screen_seq": .number(Double(receipt.screenSequence)),
                    ])
                )
                return [response, event]

            default:
                throw PhoneError(code: "unknown_method", message: "unsupported method \(method)")
            }
        } catch let error as PhoneError {
            return [.failure(id: requestID, sessionID: id, error: error)]
        } catch {
            return [.failure(
                id: requestID,
                sessionID: id,
                error: PhoneError(code: "driver_error", message: String(describing: error), retryable: true)
            )]
        }
    }

    private func decodeAction(method: String, params: PhoneJSONValue?) throws -> PhoneActionRequest {
        guard let params else {
            throw PhoneError(code: "invalid_action", message: "action params are required")
        }
        let actionID = params["action_id"]?.stringValue
            ?? params["actionId"]?.stringValue
        guard let actionID, !actionID.isEmpty else {
            throw PhoneError(code: "invalid_action", message: "action_id is required for replay safety")
        }
        let kind: PhoneActionKind
        switch method {
        case "action.tap": kind = .tap
        case "action.swipe": kind = .swipe
        case "action.long_press": kind = .longPress
        case "action.type": kind = .type
        case "action.press": kind = .press
        default: throw PhoneError(code: "invalid_action", message: "unsupported action")
        }
        let screenSequence = params["screen_seq"]?.doubleValue.map(UInt64.init)
        let point = try decodePoint(params["point"])
        let endPoint = try decodePoint(params["end_point"] ?? params["endPoint"])
        let duration = params["duration_ms"]?.doubleValue.map(Int.init)
        return PhoneActionRequest(
            actionID: actionID,
            kind: kind,
            screenSequence: screenSequence,
            point: point,
            endPoint: endPoint,
            durationMilliseconds: duration,
            text: params["text"]?.stringValue,
            button: params["button"]?.stringValue
        )
    }

    private func decodePoint(_ value: PhoneJSONValue?) throws -> PhonePoint? {
        guard let value else { return nil }
        guard let x = value["x"]?.doubleValue, let y = value["y"]?.doubleValue else {
            throw PhoneError(code: "invalid_coordinates", message: "point needs x and y")
        }
        let point = PhonePoint(x: x, y: y)
        try point.validated()
        return point
    }
}

public actor PhoneControlServer {
    private let driver: any PhoneDriver
    private var session: PhoneSession?

    public init(driver: any PhoneDriver) {
        self.driver = driver
    }

    public func handle(_ request: PhoneEnvelope) async -> [PhoneEnvelope] {
        guard request.type == .request, let requestID = request.id, let method = request.method else {
            return [.failure(
                id: request.id,
                error: PhoneError(code: "invalid_request", message: "a request needs id and method")
            )]
        }
        do {
            switch method {
            case "device.list":
                let device = try await driver.device()
                return [.response(id: requestID, result: try PhoneJSONValue([device]))]

            case "session.open":
                if session != nil {
                    throw PhoneError(code: "session_exists", message: "only one local session is supported")
                }
                let device = try await driver.device()
                let newSession = PhoneSession(driver: driver)
                session = newSession
                let result = PhoneJSONValue.object([
                    "session_id": .string(newSession.id),
                    "device": try PhoneJSONValue(device),
                    "capabilities": try PhoneJSONValue(device.capabilities),
                ])
                return [.response(id: requestID, sessionID: newSession.id, result: result)]

            default:
                guard let session else {
                    throw PhoneError(code: "session_required", message: "open a session first")
                }
                return await session.handle(request)
            }
        } catch let error as PhoneError {
            return [.failure(id: requestID, error: error)]
        } catch {
            return [.failure(
                id: requestID,
                error: PhoneError(code: "driver_error", message: String(describing: error), retryable: true)
            )]
        }
    }
}
