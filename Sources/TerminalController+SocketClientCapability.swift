import CmuxControlSocket
import CmuxSettings
import CryptoKit
import Darwin
import Foundation
import Security

struct AuthorizedSocketCommand: Sendable, Equatable {
    let command: String
    let trustedCodeRouterPeerAuditToken: SocketPeerAuditToken?
    let codeRouterHandoffSessionBinding: CodeRouterHandoffSessionBinding?
    let codeRouterHandoffArmProof: VerifiedCodeRouterHandoffArmProof?
    let codeRouterHandoffBeginAuthorization:
        CodeRouterHandoffBeginAuthorization?
}

struct CodeRouterHandoffBeginAuthorization: Sendable, Equatable {
    let peerAuditToken: SocketPeerAuditToken
    let peerProcessStartTime: SocketPeerProcessStartTime
    let sessionBinding: CodeRouterHandoffSessionBinding
}

struct PendingCodeRouterHandoffChallenge: Sendable, Equatable {
    let authorization: CodeRouterHandoffBeginAuthorization
    let challenge: String
}

struct VerifiedCodeRouterHandoffArmProof: Sendable, Equatable {
    let capability: String
    let nonce: Data
    let challenge: Data
    let processID: pid_t
    let processStartAbsoluteTime: UInt64
}

struct CodeRouterHandoffArmProofRequest: Sendable, Equatable {
    let nonce: Data
    let challenge: Data
    let processID: pid_t
    let processStartAbsoluteTime: UInt64
    let proof: String
}

private enum CodeRouterHandoffArmSessionState: Sendable {
    case notAuthenticated
    case teamRequired
    case ready(CodeRouterHandoffSessionBinding, teamBinding: String)
}

extension TerminalController {
    private nonisolated static var socketClientPreauthorizationLimits: ControlClientLineReadLimits {
        ControlClientLineReadLimits(
            maximumBytes: 4 * 1024 * 1024,
            timeoutMilliseconds: 2_000
        )
    }

    nonisolated static func makeSocketClientCapabilityAuthority(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> SocketClientCapabilityAuthority {
        let audience = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? "com.cmuxterm.app"
        let store = SocketClientCapabilitySecretStore(
            service: "\(audience).socket-client-capability"
        )
        let usesEphemeralSecret = SocketControlSettings.isDebugLikeBundleIdentifier(audience)
            || SocketControlSettings.isStagingBundleIdentifier(audience)
        let secret = usesEphemeralSecret
            ? store.makeEphemeralSecret()
            : store.loadOrCreateSecret()
        return SocketClientCapabilityAuthority(secret: secret, audience: audience)
    }

    nonisolated func socketClientCapabilityEnvironment() -> [String: String] {
        [
            SocketClientCapabilityEnvelope.environmentKey:
                socketClientCapabilityAuthority.issueCapability()
        ]
    }

    nonisolated func socketClientInitialReadLimits(
        peerProcessID: pid_t?
    ) -> ControlClientLineReadLimits? {
        guard socketServer.accessMode == .cmuxOnly,
              !(peerProcessID.map(isDescendant) ?? false) else {
            return nil
        }
        return Self.socketClientPreauthorizationLimits
    }

    nonisolated func authorizedSocketCommand(
        _ command: String,
        peerProcessID: pid_t?,
        peerHasSameUID: Bool,
        peerAuditToken: SocketPeerAuditToken? = nil,
        peerProcessStartTime: SocketPeerProcessStartTime? = nil,
        authorizationGeneration: UInt64? = nil,
        pendingCodeRouterHandoffChallenge:
            PendingCodeRouterHandoffChallenge? = nil,
        codeRouterPeerVerifier: CodeRouterSocketPeerVerifier = .production
    ) -> AuthorizedSocketCommand? {
        let potentialCodeRouterHandshake =
            Self.isCodeRouterHandoffCommand(command)
                || Self.isCodeRouterHandoffBeginCommand(command)
                || Self.isCodeRouterHandoffArmCommand(command)
        guard !potentialCodeRouterHandshake
                || command == command.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ) else {
            return nil
        }
        if Self.isCodeRouterHandoffCommand(command) {
            // Completion is valid only after this connection receives a fresh
            // server challenge. Password, ancestry, inherited capability,
            // automation, and allowAll do not mint this bearer authority.
            guard let pendingCodeRouterHandoffChallenge,
                  peerHasSameUID,
                  command.utf8.count <= 4_096,
                  SocketClientCapabilityCommand(command) == nil,
                  Self.codeRouterHandoffCompleteChallenge(command)
                    == pendingCodeRouterHandoffChallenge.challenge,
                  let peerAuditToken,
                  let peerProcessStartTime,
                  let authorizationGeneration,
                  peerAuditToken
                    == pendingCodeRouterHandoffChallenge.authorization
                        .peerAuditToken,
                  peerProcessStartTime
                    == pendingCodeRouterHandoffChallenge.authorization
                        .peerProcessStartTime,
                  codeRouterPeerVerifier.isTrusted(peerAuditToken),
                  let currentSessionBinding = currentCodeRouterHandoffSessionBinding(),
                  currentSessionBinding
                    == pendingCodeRouterHandoffChallenge.authorization
                        .sessionBinding,
                  let armedSessionBinding = codeRouterHandoffArmGrantStore.consume(
                      token: peerAuditToken,
                      processStartTime: peerProcessStartTime,
                      authorizationGeneration: authorizationGeneration,
                      currentSessionBinding: currentSessionBinding
                  ) else {
                return nil
            }
            return AuthorizedSocketCommand(
                command: SocketClientCapabilityCommand(command)?.command
                    ?? command,
                trustedCodeRouterPeerAuditToken: peerAuditToken,
                codeRouterHandoffSessionBinding: armedSessionBinding,
                codeRouterHandoffArmProof: nil,
                codeRouterHandoffBeginAuthorization: nil
            )
        }

        if Self.isCodeRouterHandoffBeginCommand(command) {
            guard pendingCodeRouterHandoffChallenge == nil,
                  peerHasSameUID,
                  command.utf8.count <= 4_096,
                  SocketClientCapabilityCommand(command) == nil,
                  Self.isValidCodeRouterProtocolRequest(
                    command,
                    method: "coderouter.handoff.begin",
                    expectedID: "coderouter-handoff-begin"
                  ),
                  let peerAuditToken,
                  let peerProcessStartTime,
                  let authorizationGeneration,
                  codeRouterPeerVerifier.isTrusted(peerAuditToken),
                  let currentSessionBinding = currentCodeRouterHandoffSessionBinding(),
                  let armedSessionBinding = codeRouterHandoffArmGrantStore
                    .sessionBindingForBegin(
                        token: peerAuditToken,
                        processStartTime: peerProcessStartTime,
                        authorizationGeneration: authorizationGeneration,
                        currentSessionBinding: currentSessionBinding
                    ) else {
                return nil
            }
            return AuthorizedSocketCommand(
                command: command,
                trustedCodeRouterPeerAuditToken: nil,
                codeRouterHandoffSessionBinding: nil,
                codeRouterHandoffArmProof: nil,
                codeRouterHandoffBeginAuthorization:
                    CodeRouterHandoffBeginAuthorization(
                        peerAuditToken: peerAuditToken,
                        peerProcessStartTime: peerProcessStartTime,
                        sessionBinding: armedSessionBinding
                    )
            )
        }

        // Arm uses proof of possession of an inherited terminal capability.
        // No password or bearer capability is written to this socket.
        if Self.isCodeRouterHandoffArmCommand(command) {
            let cmuxRealUserID = getuid()
            let cmuxEffectiveUserID = geteuid()
            guard cmuxRealUserID == cmuxEffectiveUserID,
                  peerHasSameUID,
                  command.utf8.count <= 4_096,
                  SocketClientCapabilityCommand(command) == nil,
                  let peerProcessID,
                  let peerAuditToken,
                  peerAuditToken.processID == peerProcessID,
                  peerAuditToken.realUserID == cmuxRealUserID,
                  peerAuditToken.effectiveUserID == cmuxEffectiveUserID,
                  let peerProcessStartTime,
                  let proofRequest = Self.codeRouterHandoffArmProofRequest(
                      command
                  ),
                  proofRequest.processID == peerProcessID,
                  proofRequest.processStartAbsoluteTime
                    == peerProcessStartTime.absoluteTime,
                  let capability = socketClientCapabilityAuthority
                    .issueCapability(nonce: proofRequest.nonce).nonEmpty,
                  SocketClientCapabilityProof.verifiesClientProof(
                      proofRequest.proof,
                      capability: capability,
                      nonce: proofRequest.nonce,
                      challenge: proofRequest.challenge,
                      processID: proofRequest.processID,
                      processStartAbsoluteTime:
                        proofRequest.processStartAbsoluteTime
                  ) else {
                return nil
            }
            return AuthorizedSocketCommand(
                command: command,
                trustedCodeRouterPeerAuditToken: nil,
                codeRouterHandoffSessionBinding: nil,
                codeRouterHandoffArmProof: VerifiedCodeRouterHandoffArmProof(
                    capability: capability,
                    nonce: proofRequest.nonce,
                    challenge: proofRequest.challenge,
                    processID: proofRequest.processID,
                    processStartAbsoluteTime:
                        proofRequest.processStartAbsoluteTime
                ),
                codeRouterHandoffBeginAuthorization: nil
            )
        }
        guard let authorized = SocketClientAuthorization().authorizedCommand(
            command,
            accessMode: socketServer.accessMode,
            peerProcessID: peerProcessID,
            peerHasSameUID: peerHasSameUID,
            capabilityAuthority: socketClientCapabilityAuthority,
            isDescendant: { isDescendant($0) }
        ) else { return nil }
        return AuthorizedSocketCommand(
            command: authorized,
            trustedCodeRouterPeerAuditToken: nil,
            codeRouterHandoffSessionBinding: nil,
            codeRouterHandoffArmProof: nil,
            codeRouterHandoffBeginAuthorization: nil
        )
    }

    nonisolated static func isCodeRouterHandoffCommand(_ command: String) -> Bool {
        let unwrapped = SocketClientCapabilityCommand(command)?.command ?? command
        // Use the same parser as the dispatcher. In particular, the parser
        // trims the method field; a quoted `" coderouter.handoff "` must not
        // bypass the strict authorization, secret-event suppression, or final
        // response-write gate. The preauthorization reader caps raw lines at
        // 4 MiB, so this parse remains bounded before the method-specific cap.
        guard let request = ControlRequestParser().lenientRequest(fromLine: unwrapped) else {
            return false
        }
        return request.method == "coderouter.handoff.complete"
    }

    nonisolated static func isCodeRouterHandoffBeginCommand(
        _ command: String
    ) -> Bool {
        let unwrapped = SocketClientCapabilityCommand(command)?.command
            ?? command
        guard let request = ControlRequestParser().lenientRequest(
            fromLine: unwrapped
        ) else {
            return false
        }
        return request.method == "coderouter.handoff.begin"
    }

    nonisolated static func isCodeRouterHandoffArmCommand(
        _ command: String
    ) -> Bool {
        let unwrapped = SocketClientCapabilityCommand(command)?.command
            ?? command
        guard let request = ControlRequestParser().lenientRequest(
            fromLine: unwrapped
        ) else {
            return false
        }
        return request.method == "coderouter.handoff.arm"
    }

    nonisolated static func isValidCodeRouterProtocolRequest(
        _ command: String,
        method: String,
        expectedID: String? = nil
    ) -> Bool {
        // Handshake frames use an exact JSON wire form. The connection
        // handler normally performs this check before authorization, but keep
        // it here as well so direct callers cannot turn Foundation's tolerant
        // whitespace parsing into an authorized request.
        guard method == "coderouter.handoff.begin",
              command == command.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ) else { return false }
        let unwrapped = SocketClientCapabilityCommand(command)?.command
            ?? command
        guard let rawData = unwrapped.data(using: .utf8),
              let rawObject = try? JSONSerialization.jsonObject(
                  with: rawData,
                  options: []
              ),
              let rawDictionary = rawObject as? [String: Any],
              Set(rawDictionary.keys).isSubset(of: ["id", "method", "params"]),
              rawDictionary["method"] as? String == method,
              let keyCounts = Self.codeRouterJSONKeyCounts(in: rawData),
              keyCounts[1]?["id"] == 1,
              keyCounts[1]?["method"] == 1,
              keyCounts[1]?["params"] == 1,
              keyCounts[2]?["protocolVersion"] == 1,
              let rawParams = rawDictionary["params"] as? [String: Any],
              rawParams.count == 1,
              let rawVersion = rawParams["protocolVersion"] as? NSNumber,
              CFGetTypeID(rawVersion) != CFBooleanGetTypeID(),
              Self.codeRouterJSONScalarToken(
                  key: "protocolVersion",
                  depth: 2,
                  in: rawData
              ) == Array("2".utf8),
              rawVersion.intValue == 2,
              rawVersion.doubleValue == 2 else {
            return false
        }
        guard let request = ControlRequestParser().lenientRequest(
            fromLine: unwrapped
        ), request.method == method,
           request.params.count == 1,
           request.params["protocolVersion"] == .int(2) else {
            return false
        }
        if let expectedID {
            guard rawDictionary["id"] as? String == expectedID,
                  request.id == .string(expectedID) else {
                return false
            }
        }
        return true
    }

    nonisolated static func codeRouterHandoffCompleteChallenge(
        _ command: String
    ) -> String? {
        guard command == command.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              SocketClientCapabilityCommand(command) == nil,
              let rawData = command.data(using: .utf8),
              let rawObject = try? JSONSerialization.jsonObject(
                with: rawData,
                options: []
              ),
              let rawDictionary = rawObject as? [String: Any],
              Set(rawDictionary.keys) == ["id", "method", "params"],
              rawDictionary["id"] as? String
                == "coderouter-handoff-complete",
              rawDictionary["method"] as? String
                == "coderouter.handoff.complete",
              let keyCounts = Self.codeRouterJSONKeyCounts(in: rawData),
              keyCounts[1]?["id"] == 1,
              keyCounts[1]?["method"] == 1,
              keyCounts[1]?["params"] == 1,
              let rawParams = rawDictionary["params"] as? [String: Any],
              Set(rawParams.keys) == ["protocolVersion", "challenge"],
              keyCounts[2]?["protocolVersion"] == 1,
              keyCounts[2]?["challenge"] == 1,
              let rawVersion = rawParams["protocolVersion"] as? NSNumber,
              CFGetTypeID(rawVersion) != CFBooleanGetTypeID(),
              Self.codeRouterJSONScalarToken(
                key: "protocolVersion",
                depth: 2,
                in: rawData
              ) == Array("2".utf8),
              rawVersion.intValue == 2,
              rawVersion.doubleValue == 2,
              let challenge = rawParams["challenge"] as? String,
              SocketClientCapabilityProof.decodeBase64URL32(challenge) != nil,
              let request = ControlRequestParser().lenientRequest(
                fromLine: command
              ),
              request.id == .string("coderouter-handoff-complete"),
              request.method == "coderouter.handoff.complete",
              request.params.count == 2,
              request.params["protocolVersion"] == .int(2),
              request.params["challenge"] == .string(challenge) else {
            return nil
        }
        return challenge
    }

    nonisolated static func codeRouterHandoffArmProofRequest(
        _ command: String
    ) -> CodeRouterHandoffArmProofRequest? {
        guard command == command.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              SocketClientCapabilityCommand(command) == nil,
              let rawData = command.data(using: .utf8),
              let rawObject = try? JSONSerialization.jsonObject(
                  with: rawData,
                  options: []
              ),
              let rawDictionary = rawObject as? [String: Any],
              Set(rawDictionary.keys) == ["id", "method", "params"],
              rawDictionary["id"] as? String
                == SocketClientCapabilityProof.requestID,
              rawDictionary["method"] as? String
                == SocketClientCapabilityProof.method,
              let keyCounts = Self.codeRouterJSONKeyCounts(in: rawData),
              keyCounts[1]?["id"] == 1,
              keyCounts[1]?["method"] == 1,
              keyCounts[1]?["params"] == 1,
              let rawParams = rawDictionary["params"] as? [String: Any],
              Set(rawParams.keys) == [
                  "protocolVersion",
                  "capabilityNonce",
                  "clientChallenge",
                  "clientProcessID",
                  "clientProcessStartAbsoluteTime",
                  "clientProof",
              ],
              rawParams.keys.allSatisfy({ keyCounts[2]?[$0] == 1 }),
              let rawVersion = rawParams["protocolVersion"] as? NSNumber,
              CFGetTypeID(rawVersion) != CFBooleanGetTypeID(),
              Self.codeRouterJSONScalarToken(
                  key: "protocolVersion",
                  depth: 2,
                  in: rawData
              ) == Array("2".utf8),
              rawVersion.uint64Value
                == SocketClientCapabilityProof.protocolVersion,
              rawVersion.doubleValue
                == Double(SocketClientCapabilityProof.protocolVersion),
              let nonceText = rawParams["capabilityNonce"] as? String,
              let nonce = SocketClientCapabilityProof.decodeBase64URL32(
                  nonceText
              ),
              let challengeText = rawParams["clientChallenge"] as? String,
              let challenge = SocketClientCapabilityProof.decodeBase64URL32(
                  challengeText
              ),
              let rawProcessID = rawParams["clientProcessID"] as? NSNumber,
              CFGetTypeID(rawProcessID) != CFBooleanGetTypeID(),
              rawProcessID.int64Value > 0,
              rawProcessID.int64Value <= Int64(Int32.max),
              rawProcessID.doubleValue
                == Double(rawProcessID.int64Value),
              Self.codeRouterJSONScalarToken(
                  key: "clientProcessID",
                  depth: 2,
                  in: rawData
              ) == Array(String(rawProcessID.int64Value).utf8),
              let startText = rawParams["clientProcessStartAbsoluteTime"]
                as? String,
              let start = SocketClientCapabilityProof.decodeProcessStartTime(
                  startText
              ),
              let proof = rawParams["clientProof"] as? String,
              proof.utf8.count == SocketClientCapabilityProof.byteCount * 2,
              proof.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }),
              let request = ControlRequestParser().lenientRequest(
                  fromLine: command
              ),
              request.id
                == .string(SocketClientCapabilityProof.requestID),
              request.method == SocketClientCapabilityProof.method,
              request.params.count == rawParams.count,
              request.params["protocolVersion"] == .int(2),
              request.params["clientProcessID"]
                == .int(rawProcessID.int64Value),
              request.params["capabilityNonce"] == .string(nonceText),
              request.params["clientChallenge"] == .string(challengeText),
              request.params["clientProcessStartAbsoluteTime"]
                == .string(startText),
              request.params["clientProof"] == .string(proof) else {
            return nil
        }
        return CodeRouterHandoffArmProofRequest(
            nonce: nonce,
            challenge: challenge,
            processID: pid_t(rawProcessID.int32Value),
            processStartAbsoluteTime: start,
            proof: proof
        )
    }

    /// Counts unescaped JSON object keys by nesting depth. CodeRouter uses a
    /// fixed ASCII wire schema, so escaped or duplicate keys are invalid.
    /// This rejects duplicate `method` fields that Foundation would otherwise
    /// collapse before the authorization route is selected.
    private nonisolated static func codeRouterJSONKeyCounts(
        in data: Data
    ) -> [Int: [String: Int]]? {
        let bytes = Array(data)
        var counts: [Int: [String: Int]] = [:]
        var depth = 0
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x7B || byte == 0x5B {
                depth += 1
                index += 1
                continue
            }
            if byte == 0x7D || byte == 0x5D {
                depth -= 1
                guard depth >= 0 else { return nil }
                index += 1
                continue
            }
            guard byte == 0x22 else {
                index += 1
                continue
            }
            let stringStart = index + 1
            index = stringStart
            var escaped = false
            while index < bytes.count {
                if bytes[index] == 0x5C {
                    escaped = true
                    index += 2
                    continue
                }
                if bytes[index] == 0x22 { break }
                index += 1
            }
            guard index < bytes.count else { return nil }
            let stringEnd = index
            index += 1
            var next = index
            while next < bytes.count,
                  Self.isCodeRouterJSONWhitespace(bytes[next]) {
                next += 1
            }
            guard next < bytes.count, bytes[next] == 0x3A else {
                continue
            }
            // The fixed schema does not use escaped field names.
            guard !escaped,
                  let key = String(
                      bytes: bytes[stringStart..<stringEnd],
                      encoding: .utf8
                  ) else {
                return nil
            }
            counts[depth, default: [:]][key, default: 0] += 1
        }
        return depth == 0 ? counts : nil
    }

    private nonisolated static func codeRouterJSONScalarToken(
        key expectedKey: String,
        depth expectedDepth: Int,
        in data: Data
    ) -> [UInt8]? {
        let bytes = Array(data)
        var depth = 0
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x7B || byte == 0x5B {
                depth += 1
                index += 1
                continue
            }
            if byte == 0x7D || byte == 0x5D {
                depth -= 1
                guard depth >= 0 else { return nil }
                index += 1
                continue
            }
            guard byte == 0x22 else {
                index += 1
                continue
            }
            let stringStart = index + 1
            index = stringStart
            var escaped = false
            while index < bytes.count {
                if bytes[index] == 0x5C {
                    escaped = true
                    index += 2
                    continue
                }
                if bytes[index] == 0x22 { break }
                index += 1
            }
            guard index < bytes.count else { return nil }
            let stringEnd = index
            index += 1
            guard depth == expectedDepth,
                  !escaped,
                  bytes[stringStart..<stringEnd]
                    .elementsEqual(expectedKey.utf8) else {
                continue
            }
            while index < bytes.count,
                  Self.isCodeRouterJSONWhitespace(bytes[index]) {
                index += 1
            }
            guard index < bytes.count, bytes[index] == 0x3A else {
                continue
            }
            index += 1
            while index < bytes.count,
                  Self.isCodeRouterJSONWhitespace(bytes[index]) {
                index += 1
            }
            let valueStart = index
            while index < bytes.count,
                  !Self.isCodeRouterJSONWhitespace(bytes[index]),
                  bytes[index] != 0x2C,
                  bytes[index] != 0x7D,
                  bytes[index] != 0x5D {
                index += 1
            }
            guard valueStart < index else { return nil }
            return Array(bytes[valueStart..<index])
        }
        return nil
    }

    private nonisolated static func isCodeRouterJSONWhitespace(
        _ byte: UInt8
    ) -> Bool {
        byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x20
    }

    nonisolated func processCodeRouterHandoffArmCommand(
        _ command: String,
        socket: Int32,
        peerAuditToken: SocketPeerAuditToken?,
        authorizationGeneration: UInt64,
        verifiedProof: VerifiedCodeRouterHandoffArmProof?
    ) -> String {
        guard let request = ControlRequestParser().lenientRequest(
            fromLine: command
        ), let peerAuditToken, let verifiedProof else {
            return Self.socketClientAccessDeniedResponse
        }
        let sessionBinding: CodeRouterHandoffSessionBinding
        let teamBinding: String
        switch currentCodeRouterHandoffArmSessionState() {
        case .notAuthenticated:
            return codeRouterSignedArmError(
                requestID: request.id?.foundationObject,
                code: "not_authenticated",
                message: "Sign in to cmux before arming a CodeRouter handoff",
                proof: verifiedProof
            )
        case .teamRequired:
            return codeRouterSignedArmError(
                requestID: request.id?.foundationObject,
                code: "team_required",
                message: "Select a CodeRouter team before arming a handoff",
                proof: verifiedProof
            )
        case .ready(let binding, let bindingHash):
            sessionBinding = binding
            teamBinding = bindingHash
        }
        guard let serverProof = SocketClientCapabilityProof.serverProof(
            capability: verifiedProof.capability,
            nonce: verifiedProof.nonce,
            challenge: verifiedProof.challenge,
            processID: verifiedProof.processID,
            processStartAbsoluteTime:
                verifiedProof.processStartAbsoluteTime,
            teamBinding: teamBinding
        ) else {
            return Self.socketClientAccessDeniedResponse
        }

        // Re-read both kernel process values after the complete proof line and
        // immediately before the atomic reservation. A relayed socket has the
        // wrong PID/start tuple and cannot arm.
        guard transport.peerProcessID(of: socket) == verifiedProof.processID,
              transport.processStartTime(of: verifiedProof.processID)?
                .absoluteTime == verifiedProof.processStartAbsoluteTime,
              transport.peerAuditToken(of: socket) == peerAuditToken,
              peerAuditToken.processID == verifiedProof.processID else {
            return Self.socketClientAccessDeniedResponse
        }
        let armResult = codeRouterHandoffArmGrantStore.armWithResult(
            token: peerAuditToken,
            processStartTime: SocketPeerProcessStartTime(
                absoluteTime: verifiedProof.processStartAbsoluteTime
            ),
            authorizationGeneration: authorizationGeneration,
            sessionBinding: sessionBinding,
            capabilityNonce: verifiedProof.nonce,
            clientChallenge: verifiedProof.challenge
        )
        switch armResult {
        case .replay:
            return v2Error(
                id: request.id?.foundationObject,
                code: "access_denied",
                message: "Access denied"
            )
        case .busy:
            return codeRouterSignedArmError(
                requestID: request.id?.foundationObject,
                code: "coderouter_handoff_arm_busy",
                message: "Too many CodeRouter handoff launches are pending",
                proof: verifiedProof
            )
        case .armed:
            return v2Ok(
                id: request.id?.foundationObject,
                result: [
                    "armed": true,
                    "protocolVersion": 2,
                    "teamBinding": teamBinding,
                    "serverProof": serverProof,
                ]
            )
        }
    }

    private nonisolated func codeRouterSignedArmError(
        requestID: Any?,
        code: String,
        message: String,
        proof: VerifiedCodeRouterHandoffArmProof
    ) -> String {
        guard let serverProof = SocketClientCapabilityProof.serverErrorProof(
            capability: proof.capability,
            nonce: proof.nonce,
            challenge: proof.challenge,
            processID: proof.processID,
            processStartAbsoluteTime: proof.processStartAbsoluteTime,
            code: code
        ) else {
            return Self.socketClientAccessDeniedResponse
        }
        return v2Error(
            id: requestID,
            code: code,
            message: message,
            data: ["serverProof": serverProof]
        )
    }

    nonisolated static func codeRouterTeamBinding(teamID: String?) -> String? {
        guard let teamID,
              1...200 ~= teamID.utf8.count,
              teamID.unicodeScalars.allSatisfy({ scalar in
                  let category = scalar.properties.generalCategory
                  return !scalar.properties.isWhitespace
                      && category != .control
                      && category != .format
              }) else {
            return nil
        }
        let prefix = Data("cmux-coderouter-team-v1\0".utf8)
        let digest = SHA256.hash(data: prefix + Data(teamID.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func makeCodeRouterHandoffChallenge(
        randomBytes: @Sendable () -> Data = {
            var bytes = Data(count: SocketClientCapabilityProof.byteCount)
            let status = bytes.withUnsafeMutableBytes { buffer in
                SecRandomCopyBytes(
                    kSecRandomDefault,
                    buffer.count,
                    buffer.baseAddress!
                )
            }
            return status == errSecSuccess ? bytes : Data()
        }
    ) -> String? {
        let bytes = randomBytes()
        guard bytes.count == SocketClientCapabilityProof.byteCount else {
            return nil
        }
        return SocketClientCapabilityProof.encodeBase64URL32(bytes)
    }

    private nonisolated func currentCodeRouterHandoffSessionBinding()
        -> CodeRouterHandoffSessionBinding? {
        v2MainSync(commandKey: "coderouter.handoff.complete") {
            guard let coordinator = self.authCoordinator,
                  coordinator.isAuthenticated else {
                return nil
            }
            return CodeRouterHandoffSessionBinding(
                authSessionGeneration: coordinator.authSessionGeneration,
                resolvedTeamID: coordinator.resolvedTeamID
            )
        }
    }

    private nonisolated func currentCodeRouterHandoffArmSessionState()
        -> CodeRouterHandoffArmSessionState {
        v2MainSync(commandKey: "coderouter.handoff.arm") {
            guard let coordinator = self.authCoordinator,
                  coordinator.isAuthenticated else {
                return .notAuthenticated
            }
            let binding = CodeRouterHandoffSessionBinding(
                authSessionGeneration: coordinator.authSessionGeneration,
                resolvedTeamID: coordinator.resolvedTeamID
            )
            guard let teamBinding = Self.codeRouterTeamBinding(
                teamID: binding.resolvedTeamID
            ) else {
                return .teamRequired
            }
            return .ready(binding, teamBinding: teamBinding)
        }
    }

    nonisolated func passwordAuthRequiredResponse(for command: String) -> String {
        let message = "Authentication required. Send auth <password> first."
        guard command.hasPrefix("{"),
              let data = command.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return "ERROR: Authentication required — send auth <password> first"
        }
        let id = dict["id"]
        return v2Error(id: id, code: "auth_required", message: message)
    }

    nonisolated func passwordLoginV1ResponseIfNeeded(
        for command: String,
        passwordAuthorization: inout SocketPasswordAuthorization
    ) -> String? {
        let lowered = command.lowercased()
        guard lowered == "auth" || lowered.hasPrefix("auth ") else {
            return nil
        }
        guard passwordStore.hasConfiguredPassword(allowLazyKeychainFallback: true) else {
            return "ERROR: Password mode is enabled but no socket password is configured in Settings."
        }

        let provided: String
        if lowered == "auth" {
            provided = ""
        } else {
            provided = String(command.dropFirst(5))
        }
        guard !provided.isEmpty else {
            return "ERROR: Missing password. Usage: auth <password>"
        }
        guard passwordStore.verify(password: provided, allowLazyKeychainFallback: true) else {
            return "ERROR: Invalid password"
        }
        passwordAuthorization.authenticate(password: provided)
        return "OK: Authenticated"
    }

    nonisolated func passwordLoginV2ResponseIfNeeded(
        for command: String,
        passwordAuthorization: inout SocketPasswordAuthorization
    ) -> String? {
        guard command.hasPrefix("{"),
              let data = command.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }
        let id = dict["id"]
        let method = (dict["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard method == "auth.login" else {
            return nil
        }

        guard let params = dict["params"] as? [String: Any],
              let provided = params["password"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "auth.login requires params.password")
        }

        guard passwordStore.hasConfiguredPassword(allowLazyKeychainFallback: true) else {
            return v2Error(
                id: id,
                code: "auth_unconfigured",
                message: "Password mode is enabled but no socket password is configured in Settings."
            )
        }

        guard passwordStore.verify(password: provided, allowLazyKeychainFallback: true) else {
            return v2Error(id: id, code: "auth_failed", message: "Invalid password")
        }
        passwordAuthorization.authenticate(password: provided)
        return v2Ok(id: id, result: ["authenticated": true])
    }

    nonisolated func authResponseIfNeeded(
        for command: String,
        passwordAuthorization: inout SocketPasswordAuthorization
    ) -> String? {
        guard socketServer.accessMode.requiresPasswordAuth else {
            return nil
        }
        if let v2Response = passwordLoginV2ResponseIfNeeded(
            for: command,
            passwordAuthorization: &passwordAuthorization
        ) {
            return v2Response
        }
        if let v1Response = passwordLoginV1ResponseIfNeeded(
            for: command,
            passwordAuthorization: &passwordAuthorization
        ) {
            return v1Response
        }
        if !passwordAuthorization.isAuthenticated {
            return passwordAuthRequiredResponse(for: command)
        }
        return nil
    }

    /// Checks both listener policy generation and password credential revision.
    nonisolated func socketAuthorizationIsCurrent(
        _ authorizationGeneration: UInt64,
        passwordAuthorization: inout SocketPasswordAuthorization
    ) -> Bool {
        socketServer.isConnectionAuthorizationCurrent(
            authorizationGeneration,
            passwordAuthorization: passwordAuthorization
        )
    }

    nonisolated func socketEventStreamAuthorizationIsCurrent(
        _ authorizationGeneration: UInt64,
        passwordAuthorization: inout SocketPasswordAuthorization
    ) -> Bool {
        socketAuthorizationIsCurrent(
            authorizationGeneration,
            passwordAuthorization: &passwordAuthorization
        )
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
