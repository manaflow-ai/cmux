import Foundation

/// What the caller has to do with one incoming ACP message.
///
/// The router performs no I/O: it reads a decoded message and says what should
/// happen. The socket calls and the stdio writes live in the CLI, so every
/// routing decision (which method needs a session id, what a deferred method
/// answers, whether a notification may be answered at all) is testable without
/// a running cmux.
public enum ACPRouterOutcome {
    /// Answer immediately with this result object.
    case respond(id: ACPRequestIdentifier, result: [String: Any])
    /// Read the live session registry, then answer.
    case listSessions(id: ACPRequestIdentifier)
    /// Replay this session's transcript as `session/update` notifications,
    /// then answer.
    case loadSession(id: ACPRequestIdentifier, sessionID: String)
    /// Answer with a JSON-RPC error.
    case fail(id: ACPRequestIdentifier?, code: Int, message: String)
    /// A notification, or a request that must produce no reply. The method is
    /// carried so the caller can log what it dropped.
    case ignore(method: String)
}

/// Routes ACP requests for the read-only phase of `cmux acp`.
public struct ACPHostRouter {
    public init() {}

    /// Decides what one decoded message means.
    public func route(_ message: ACPIncomingMessage) -> ACPRouterOutcome {
        // A notification can never be answered, not even with an error, so the
        // notification check comes before any method-specific handling. ACP
        // sends `session/cancel` as a notification, which means a read-only
        // host must drop it silently rather than report it as unimplemented.
        guard let id = message.id else { return .ignore(method: message.method) }

        switch ACPHostMethod(rawValue: message.method) {
        case .some(.initialize):
            let requested = message.params["protocolVersion"] as? Int
            return .respond(
                id: id,
                result: ACPHostCapabilities().initializeResult(clientProtocolVersion: requested)
            )

        case .some(.authenticate):
            // No auth methods are advertised, so there is nothing to check and
            // nothing to refuse. Succeeding is the honest answer: a client that
            // calls this anyway is already authorized by owning the socket.
            return .respond(id: id, result: [:])

        case .some(.cmuxSessionList):
            return .listSessions(id: id)

        case .some(.sessionLoad):
            guard let sessionID = Self.nonEmptyString(message.params["sessionId"]) else {
                return .fail(
                    id: id,
                    code: ACPErrorCode.invalidParams.rawValue,
                    message: "session/load needs a non-empty sessionId. "
                        + "Use _cmux/session/list to get the live session ids."
                )
            }
            return .loadSession(id: id, sessionID: sessionID)

        case .some(let method):
            if let phase = ACPHostMethod.deferredMethods[method.rawValue] {
                return .fail(
                    id: id,
                    code: ACPErrorCode.methodNotFound.rawValue,
                    message: "\(message.method) is not implemented in this build. "
                        + "It lands in \(phase); this host is read-only."
                )
            }
            // A name this host knows but does not answer as a request.
            // `session/update` is the notification the host sends, so a client
            // calling it has the direction backwards.
            return .fail(
                id: id,
                code: ACPErrorCode.methodNotFound.rawValue,
                message: "\(message.method) is not a request this host answers."
            )
        case .none:
            return .fail(
                id: id,
                code: ACPErrorCode.methodNotFound.rawValue,
                message: "Unknown method \(message.method)."
            )
        }
    }

    /// The JSON-RPC answer for a line that could not be decoded.
    ///
    /// Returns a JSON-RPC error with a null id when the problem left no id to
    /// answer. The caller can report it and keep reading the next line.
    public func failure(for problem: ACPIncomingMessage.Problem) -> [String: Any]? {
        switch problem {
        case .notJSON:
            return ACPOutgoingMessage.failure(
                id: nil,
                code: .parseError,
                message: "Invalid JSON.",
                data: nil
            ).envelope
        case .notAnObject:
            return ACPOutgoingMessage.failure(
                id: nil,
                code: .invalidRequest,
                message: "JSON-RPC message must be an object.",
                data: nil
            ).envelope
        case .wrongVersion(let found):
            let seen = found.map { "'\($0)'" } ?? "nothing"
            return ACPOutgoingMessage.failure(
                id: nil,
                code: .invalidRequest,
                message: "Expected \"jsonrpc\": \"2.0\", found \(seen).",
                data: nil
            ).envelope
        case .missingMethod(let id):
            return ACPOutgoingMessage.failure(
                id: id,
                code: .invalidRequest,
                message: "Missing method.",
                data: nil
            ).envelope
        case .paramsNotAnObject(let id):
            return ACPOutgoingMessage.failure(
                id: id,
                code: .invalidParams,
                message: "params must be an object.",
                data: nil
            ).envelope
        }
    }

    /// Trims and rejects whitespace, so `"sessionId": " "` fails as a bad
    /// parameter rather than as a session that does not exist.
    static func nonEmptyString(_ raw: Any?) -> String? {
        guard let text = raw as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
