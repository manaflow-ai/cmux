public import Darwin
public import Foundation

/// Validates and creates the native CodeRouter handoff wire values.
///
/// This value does not open a socket and does not perform peer verification.
/// It owns only the canonical arm request and response shapes.
public struct CodeRouterHandoffProtocol {
    /// The current native handoff protocol version.
    public static let protocolVersion = 2

    /// The maximum byte count for one request or response, including newline.
    public static let maximumRawFrameBytes = 4_096

    /// A successful arm result that the cmux CLI passes to CodeRouter.
    public struct Arm: Equatable, Sendable {
        /// The absolute path of the cmux Unix-domain socket.
        public let socketPath: String

        /// The lowercase SHA-256 binding for the selected team.
        public let teamBinding: String

        /// Creates one validated handoff result.
        ///
        /// - Parameters:
        ///   - socketPath: The absolute cmux Unix-domain socket path.
        ///   - teamBinding: The 64-character lowercase team binding.
        public init(socketPath: String, teamBinding: String) {
            self.socketPath = socketPath
            self.teamBinding = teamBinding
        }
    }

    /// The secret proof state that binds one arm request and response.
    public struct ProofContext {
        fileprivate let capability: String

        let nonce: Data
        let challenge: Data
        let processID: pid_t
        let processStartAbsoluteTime: UInt64

        /// The exact JSON parameters for `coderouter.handoff.arm`.
        public let requestParams: [String: Any]

        fileprivate init(
            capability: String,
            nonce: Data,
            challenge: Data,
            processID: pid_t,
            processStartAbsoluteTime: UInt64,
            requestParams: [String: Any]
        ) {
            self.capability = capability
            self.nonce = nonce
            self.challenge = challenge
            self.processID = processID
            self.processStartAbsoluteTime = processStartAbsoluteTime
            self.requestParams = requestParams
        }
    }

    /// A verified arm response from the cmux server.
    public enum VerifiedResponse: Equatable, Sendable {
        /// The server armed the process for the specified team binding.
        case armed(teamBinding: String)

        /// The server returned an allow-listed, authenticated error code.
        case signedError(code: String)
    }

    /// Creates a handoff protocol codec.
    public init() {}

    /// Tests whether a socket path has the canonical Darwin wire form.
    ///
    /// - Parameter socketPath: The socket path to validate.
    /// - Returns: `true` only for an absolute path of at most 103 UTF-8 bytes
    ///   that contains no Unicode control or format scalar.
    public func socketPathIsValid(_ socketPath: String) -> Bool {
        socketPath.hasPrefix("/")
            && socketPath.utf8.count <= 103
            && socketPath.unicodeScalars.allSatisfy { scalar in
                switch scalar.properties.generalCategory {
                case .control, .format:
                    false
                default:
                    true
                }
            }
    }

    /// Creates a proof-bound arm request context.
    ///
    /// - Parameters:
    ///   - capability: The canonical terminal capability. It does not enter
    ///     the returned JSON parameters.
    ///   - challenge: A fresh 32-byte client challenge.
    ///   - processID: The process that will replace itself with CodeRouter.
    ///   - processStartAbsoluteTime: The stable process start time from
    ///     `proc_pid_rusage`.
    /// - Returns: A proof context, or `nil` when an input is not canonical.
    public func makeProofContext(
        capability: String,
        challenge: Data,
        processID: pid_t,
        processStartAbsoluteTime: UInt64
    ) -> ProofContext? {
        guard let nonce = SocketClientCapabilityProof.capabilityNonce(
            from: capability
        ),
        let nonceText = SocketClientCapabilityProof.encodeBase64URL32(nonce),
        let challengeText = SocketClientCapabilityProof.encodeBase64URL32(
            challenge
        ),
        let processStartText = SocketClientCapabilityProof
            .encodeProcessStartTime(processStartAbsoluteTime),
        let clientProof = SocketClientCapabilityProof.clientProof(
            capability: capability,
            nonce: nonce,
            challenge: challenge,
            processID: processID,
            processStartAbsoluteTime: processStartAbsoluteTime
        ) else {
            return nil
        }

        return ProofContext(
            capability: capability,
            nonce: nonce,
            challenge: challenge,
            processID: processID,
            processStartAbsoluteTime: processStartAbsoluteTime,
            requestParams: [
                "protocolVersion": Int(
                    SocketClientCapabilityProof.protocolVersion
                ),
                "capabilityNonce": nonceText,
                "clientChallenge": challengeText,
                "clientProcessID": Int(processID),
                "clientProcessStartAbsoluteTime": processStartText,
                "clientProof": clientProof,
            ]
        )
    }

    /// Verifies one strict server arm result against its request context.
    ///
    /// The caller must first validate the raw JSON with
    /// ``responseRawShapeIsValid(_:)`` so Foundation cannot hide duplicate
    /// keys or coerce scalar types.
    ///
    /// - Parameters:
    ///   - envelope: The parsed response object.
    ///   - context: The context that created the arm request.
    /// - Returns: The authenticated result, or `nil` for any mismatch.
    public func verifyResponse(
        _ envelope: [String: Any],
        context: ProofContext
    ) -> VerifiedResponse? {
        if Set(envelope.keys) == ["id", "ok", "result"],
           envelope["id"] as? String == SocketClientCapabilityProof.requestID,
           envelope["ok"] as? Bool == true,
           let result = envelope["result"] as? [String: Any],
           Set(result.keys) == [
               "armed",
               "protocolVersion",
               "teamBinding",
               "serverProof",
           ],
           result["armed"] as? Bool == true,
           result["protocolVersion"] as? Int == Self.protocolVersion,
           let teamBinding = result["teamBinding"] as? String,
           let serverProof = result["serverProof"] as? String,
           SocketClientCapabilityProof.verifiesServerProof(
               serverProof,
               capability: context.capability,
               nonce: context.nonce,
               challenge: context.challenge,
               processID: context.processID,
               processStartAbsoluteTime: context.processStartAbsoluteTime,
               teamBinding: teamBinding
           ) {
            return .armed(teamBinding: teamBinding)
        }

        guard Set(envelope.keys) == ["id", "ok", "error"],
              envelope["id"] as? String
                  == SocketClientCapabilityProof.requestID,
              envelope["ok"] as? Bool == false,
              let responseError = envelope["error"] as? [String: Any],
              Set(responseError.keys) == ["code", "message", "data"],
              let code = responseError["code"] as? String,
              responseError["message"] is String,
              let errorData = responseError["data"] as? [String: Any],
              Set(errorData.keys) == ["serverProof"],
              let serverProof = errorData["serverProof"] as? String,
              SocketClientCapabilityProof.verifiesServerErrorProof(
                  serverProof,
                  capability: context.capability,
                  nonce: context.nonce,
                  challenge: context.challenge,
                  processID: context.processID,
                  processStartAbsoluteTime: context
                      .processStartAbsoluteTime,
                  code: code
              ) else {
            return nil
        }
        return .signedError(code: code)
    }

    /// Checks the response before Foundation can coerce number types or
    /// collapse duplicate object keys.
    /// Validates the exact raw JSON shape of one arm response.
    ///
    /// - Parameter rawResponse: The UTF-8 response without its final newline.
    /// - Returns: `true` only for an exact success or signed-error schema.
    public func responseRawShapeIsValid(_ rawResponse: String) -> Bool {
        guard rawResponse == rawResponse.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              let fields = rawJSONFields(rawResponse) else {
            return false
        }
        guard rawJSONFieldNames(fields, depth: 1)
                == ["id", "ok", "result"] else {
            return rawErrorShapeIsValid(fields)
        }
        guard rawJSONValue(fields, name: "id", depth: 1)
                == Array(#""coderouter-handoff-arm""#.utf8),
              rawJSONValue(fields, name: "ok", depth: 1)
                == Array("true".utf8),
              rawJSONFieldNames(fields, depth: 2) == [
                  "armed",
                  "protocolVersion",
                  "serverProof",
                  "teamBinding",
              ],
              !fields.contains(where: { $0.depth > 2 }),
              rawJSONValue(fields, name: "armed", depth: 2)
                == Array("true".utf8),
              rawJSONValue(fields, name: "protocolVersion", depth: 2)
                == Array("2".utf8) else {
            return false
        }
        return true
    }

    private struct RawJSONField {
        let depth: Int
        let name: String
        let valueToken: [UInt8]?
    }

    private func rawErrorShapeIsValid(
        _ fields: [RawJSONField]
    ) -> Bool {
        rawJSONFieldNames(fields, depth: 1) == ["error", "id", "ok"]
            && rawJSONValue(fields, name: "id", depth: 1)
                == Array(#""coderouter-handoff-arm""#.utf8)
            && rawJSONValue(fields, name: "ok", depth: 1)
                == Array("false".utf8)
            && rawJSONFieldNames(fields, depth: 2)
                == ["code", "data", "message"]
            && rawJSONFieldNames(fields, depth: 3) == ["serverProof"]
            && !fields.contains(where: { $0.depth > 3 })
    }

    private func rawJSONFieldNames(
        _ fields: [RawJSONField],
        depth: Int
    ) -> [String] {
        fields.filter { $0.depth == depth }.map(\.name).sorted()
    }

    private func rawJSONValue(
        _ fields: [RawJSONField],
        name: String,
        depth: Int
    ) -> [UInt8]? {
        let matches = fields.filter {
            $0.depth == depth && $0.name == name
        }
        guard matches.count == 1 else { return nil }
        return matches[0].valueToken
    }

    private func rawJSONFields(
        _ rawResponse: String
    ) -> [RawJSONField]? {
        let bytes = Array(rawResponse.utf8)
        var fields: [RawJSONField] = []
        var objectDepth = 0
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case 0x7B: // {
                objectDepth += 1
                index += 1
            case 0x7D: // }
                objectDepth -= 1
                guard objectDepth >= 0 else { return nil }
                index += 1
            case 0x22: // "
                let stringStart = index
                guard let stringEnd = rawJSONStringEnd(
                    in: bytes,
                    startingAt: stringStart
                ) else {
                    return nil
                }
                let content = bytes[(stringStart + 1)..<(stringEnd - 1)]
                var cursor = stringEnd
                while cursor < bytes.count,
                      rawJSONIsWhitespace(bytes[cursor]) {
                    cursor += 1
                }
                if objectDepth > 0,
                   cursor < bytes.count,
                   bytes[cursor] == 0x3A {
                    guard !content.contains(0x5C),
                          let name = String(
                              bytes: content,
                              encoding: .utf8
                          ) else {
                        return nil
                    }
                    cursor += 1
                    while cursor < bytes.count,
                          rawJSONIsWhitespace(bytes[cursor]) {
                        cursor += 1
                    }
                    fields.append(RawJSONField(
                        depth: objectDepth,
                        name: name,
                        valueToken: rawJSONScalarToken(
                            in: bytes,
                            startingAt: cursor
                        )
                    ))
                }
                index = stringEnd
            default:
                index += 1
            }
        }
        return objectDepth == 0 ? fields : nil
    }

    private func rawJSONStringEnd(
        in bytes: [UInt8],
        startingAt start: Int
    ) -> Int? {
        guard start < bytes.count, bytes[start] == 0x22 else { return nil }
        var index = start + 1
        while index < bytes.count {
            if bytes[index] == 0x5C {
                index += 2
                continue
            }
            if bytes[index] == 0x22 {
                return index + 1
            }
            index += 1
        }
        return nil
    }

    private func rawJSONScalarToken(
        in bytes: [UInt8],
        startingAt start: Int
    ) -> [UInt8]? {
        guard start < bytes.count else { return nil }
        if bytes[start] == 0x22 {
            guard let end = rawJSONStringEnd(
                in: bytes,
                startingAt: start
            ) else {
                return nil
            }
            return Array(bytes[start..<end])
        }
        var end = start
        while end < bytes.count,
              !rawJSONIsWhitespace(bytes[end]),
              bytes[end] != 0x2C,
              bytes[end] != 0x7D,
              bytes[end] != 0x5D {
            end += 1
        }
        return start < end ? Array(bytes[start..<end]) : nil
    }

    private func rawJSONIsWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x20
    }
}
