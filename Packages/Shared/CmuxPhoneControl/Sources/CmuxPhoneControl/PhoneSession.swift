import Foundation

public actor PhoneSession {
    private struct ActionRecord: Sendable {
        let request: PhoneActionRequest
        let receipt: PhoneActionReceipt
    }

    private static let maxActionRecords = 256
    private static let maxActionIDBytes = 256
    public nonisolated let id: String

    private let driver: any PhoneDriver
    private var currentSequence: UInt64 = 0
    private var closed = false
    private var actionRecords: [String: ActionRecord] = [:]
    private var actionRecordOrder: [String] = []
    private var inFlightActions: [String: PhoneActionRequest] = [:]

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
                if let previous = actionRecords[action.actionID] {
                    guard previous.request == action else {
                        throw PhoneError(
                            code: "action_id_conflict",
                            message: "action_id was already used for a different action"
                        )
                    }
                    let duplicate = PhoneActionReceipt(
                        actionID: previous.receipt.actionID,
                        accepted: previous.receipt.accepted,
                        duplicate: true,
                        screenSequence: previous.receipt.screenSequence,
                        detail: previous.receipt.detail
                    )
                    return [.response(
                        id: requestID,
                        sessionID: id,
                        result: try PhoneJSONValue(duplicate)
                    )]
                }
                if let expected = action.screenSequence, expected != currentSequence {
                    throw PhoneError(
                        code: "stale_screen",
                        message: "action references screen sequence \(expected), current is \(currentSequence)",
                        retryable: true,
                        details: .object(["current_seq": .number(Double(currentSequence))])
                    )
                }
                if let pending = inFlightActions[action.actionID] {
                    guard pending == action else {
                        throw PhoneError(
                            code: "action_id_conflict",
                            message: "action_id is already being used for a different action"
                        )
                    }
                    throw PhoneError(
                        code: "action_in_progress",
                        message: "an action with this action_id is still in progress",
                        retryable: true
                    )
                }
                inFlightActions[action.actionID] = action
                defer { inFlightActions.removeValue(forKey: action.actionID) }
                let receipt = try await driver.perform(action)
                currentSequence = receipt.screenSequence
                remember(action: action, receipt: receipt)
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
        } catch let error as PhoneDriverError {
            let (code, retryable): (String, Bool) = switch error {
            case .unsupported: ("capability_unavailable", false)
            case .unavailable: ("device_unavailable", true)
            case .transport: ("transport_error", true)
            case .malformedResponse: ("malformed_driver_response", false)
            }
            return [.failure(
                id: requestID,
                sessionID: id,
                error: PhoneError(code: code, message: String(describing: error), retryable: retryable)
            )]
        } catch {
            return [.failure(
                id: requestID,
                sessionID: id,
                error: PhoneError(code: "driver_error", message: String(describing: error), retryable: true)
            )]
        }
    }

    private func remember(action: PhoneActionRequest, receipt: PhoneActionReceipt) {
        actionRecords[action.actionID] = ActionRecord(request: action, receipt: receipt)
        actionRecordOrder.removeAll { $0 == action.actionID }
        actionRecordOrder.append(action.actionID)
        if actionRecordOrder.count > Self.maxActionRecords {
            let evicted = actionRecordOrder.removeFirst()
            actionRecords.removeValue(forKey: evicted)
        }
    }

    private func decodeAction(method: String, params: PhoneJSONValue?) throws -> PhoneActionRequest {
        guard let params else {
            throw PhoneError(code: "invalid_action", message: "action params are required")
        }
        let actionID = params["action_id"]?.stringValue
            ?? params["actionId"]?.stringValue
        guard let actionID, !actionID.isEmpty,
              actionID.utf8.count <= Self.maxActionIDBytes else {
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
        let screenSequence = try exactUInt(params["screen_seq"]?.doubleValue, field: "screen_seq")
        let point = try decodePoint(params["point"])
        let endPoint = try decodePoint(params["end_point"] ?? params["endPoint"])
        let duration = try exactDuration(params["duration_ms"]?.doubleValue)
        switch kind {
        case .tap, .longPress:
            guard point != nil, endPoint == nil else {
                throw PhoneError(code: "invalid_action", message: "\(kind.rawValue) requires point")
            }
        case .swipe:
            guard point != nil, endPoint != nil else {
                throw PhoneError(code: "invalid_action", message: "swipe requires point and end_point")
            }
        case .type:
            guard let text = params["text"]?.stringValue, !text.isEmpty else {
                throw PhoneError(code: "invalid_action", message: "type requires non-empty text")
            }
        case .press:
            guard let button = params["button"]?.stringValue, !button.isEmpty else {
                throw PhoneError(code: "invalid_action", message: "press requires button")
            }
        }
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

    private func exactUInt(_ value: Double?, field: String) throws -> UInt64? {
        guard let value else { return nil }
        guard value.isFinite, value >= 0, value.rounded() == value, value <= Double(Int64.max) else {
            throw PhoneError(code: "invalid_action", message: "\(field) must be a non-negative integer")
        }
        return UInt64(value)
    }

    private func exactDuration(_ value: Double?) throws -> Int? {
        guard let value else { return nil }
        guard value.isFinite, value.rounded() == value, (1...60_000).contains(value) else {
            throw PhoneError(code: "invalid_action", message: "duration_ms must be between 1 and 60000")
        }
        return Int(value)
    }
}

public actor PhoneControlServer {
    private let driver: any PhoneDriver
    private var session: PhoneSession?
    private var openingSession = false

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
                if session != nil || openingSession {
                    throw PhoneError(code: "session_exists", message: "only one local session is supported")
                }
                openingSession = true
                defer { openingSession = false }
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
                let responses = await session.handle(request)
                if method == "session.close", responses.first?.type == .response {
                    self.session = nil
                }
                return responses
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

    public func resetSession() {
        session = nil
    }
}
