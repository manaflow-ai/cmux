internal import CryptoKit
public import Darwin
public import Foundation

/// Canonical proof-of-possession wire codec for CodeRouter handoff arming.
///
/// The full terminal capability never crosses the socket. Both peers use it
/// to derive separate client and server HMAC keys, then use this shared codec
/// so field order or integer encoding cannot drift.
public enum SocketClientCapabilityProof {
    public static let protocolVersion: UInt64 = 2
    public static let requestID = "coderouter-handoff-arm"
    public static let method = "coderouter.handoff.arm"
    public static let byteCount = 32
    public static let proofVersion: UInt32 = 1
    public static let signedErrorCodes: Set<String> = [
        "coderouter_handoff_arm_busy",
        "not_authenticated",
        "team_required",
    ]

    private static let requestDomain = Data(
        "cmux-coderouter-arm/request/v1\0".utf8
    )
    private static let resultDomain = Data(
        "cmux-coderouter-arm/result/v1\0".utf8
    )
    private static let clientKeyDomain = Data(
        "cmux-coderouter-arm/client-key/v1\0".utf8
    )
    private static let serverKeyDomain = Data(
        "cmux-coderouter-arm/server-key/v1\0".utf8
    )

    /// Extracts the canonical 32-byte nonce from a complete v1 capability.
    public static func capabilityNonce(from capability: String) -> Data? {
        let components = capability.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard capability.utf8.count == 90,
              capability.unicodeScalars.allSatisfy({ $0.isASCII }),
              components.count == 3,
              components[0] == "v1",
              let nonce = decodeBase64URL32(String(components[1])),
              let signature = decodeBase64URL32(String(components[2])),
              "v1.\(encodeBase64URL32(nonce) ?? "").\(encodeBase64URL32(signature) ?? "")"
                == capability else {
            return nil
        }
        return nonce
    }

    /// Encodes one 32-byte nonce or challenge for JSON.
    public static func encodeBase64URL32(_ data: Data) -> String? {
        guard data.count == byteCount else { return nil }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes only the canonical unpadded base64url representation of 32 bytes.
    public static func decodeBase64URL32(_ value: String) -> Data? {
        guard value.utf8.count == 43,
              value.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 45, 48...57, 65...90, 95, 97...122:
                      return true
                  default:
                      return false
                  }
              }) else {
            return nil
        }
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append("=")
        guard let data = Data(base64Encoded: base64),
              data.count == byteCount,
              encodeBase64URL32(data) == value else {
            return nil
        }
        return data
    }

    /// Encodes `ri_proc_start_abstime` as exactly 16 lowercase hex digits.
    public static func encodeProcessStartTime(_ value: UInt64) -> String? {
        guard value > 0 else { return nil }
        return String(format: "%016llx", value)
    }

    /// Decodes the exact 16-lowercase-hex process launch value.
    public static func decodeProcessStartTime(_ value: String) -> UInt64? {
        guard value.utf8.count == 16,
              value.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }),
              let parsed = UInt64(value, radix: 16),
              parsed > 0,
              encodeProcessStartTime(parsed) == value else {
            return nil
        }
        return parsed
    }

    /// Creates the canonical lowercase-hex client HMAC.
    public static func clientProof(
        capability: String,
        nonce: Data,
        challenge: Data,
        processID: pid_t,
        processStartAbsoluteTime: UInt64
    ) -> String? {
        guard capabilityNonce(from: capability) == nonce,
              let transcript = clientTranscript(
                  nonce: nonce,
                  challenge: challenge,
                  processID: processID,
                  processStartAbsoluteTime: processStartAbsoluteTime
              ) else {
            return nil
        }
        return hmacHex(capability: capability, message: transcript)
    }

    /// Verifies one canonical client HMAC in constant time.
    public static func verifiesClientProof(
        _ proof: String,
        capability: String,
        nonce: Data,
        challenge: Data,
        processID: pid_t,
        processStartAbsoluteTime: UInt64
    ) -> Bool {
        guard capabilityNonce(from: capability) == nonce,
              let proofBytes = decodeLowercaseHex32(proof),
              let transcript = clientTranscript(
                  nonce: nonce,
                  challenge: challenge,
                  processID: processID,
                  processStartAbsoluteTime: processStartAbsoluteTime
              ) else {
            return false
        }
        return HMAC<SHA256>.isValidAuthenticationCode(
            proofBytes,
            authenticating: transcript,
            using: derivedKey(capability: capability, domain: clientKeyDomain)
        )
    }

    /// Creates the canonical lowercase-hex server result HMAC.
    public static func serverProof(
        capability: String,
        nonce: Data,
        challenge: Data,
        processID: pid_t,
        processStartAbsoluteTime: UInt64,
        teamBinding: String
    ) -> String? {
        guard capabilityNonce(from: capability) == nonce,
              let transcript = serverSuccessTranscript(
                  nonce: nonce,
                  challenge: challenge,
                  processID: processID,
                  processStartAbsoluteTime: processStartAbsoluteTime,
                  teamBinding: teamBinding
              ) else {
            return nil
        }
        return serverHMAC(capability: capability, message: transcript)
    }

    /// Verifies the server proof before the launcher accepts an arm result.
    public static func verifiesServerProof(
        _ proof: String,
        capability: String,
        nonce: Data,
        challenge: Data,
        processID: pid_t,
        processStartAbsoluteTime: UInt64,
        teamBinding: String
    ) -> Bool {
        guard capabilityNonce(from: capability) == nonce,
              let proofBytes = decodeLowercaseHex32(proof),
              let transcript = serverSuccessTranscript(
                  nonce: nonce,
                  challenge: challenge,
                  processID: processID,
                  processStartAbsoluteTime: processStartAbsoluteTime,
                  teamBinding: teamBinding
              ) else {
            return false
        }
        return HMAC<SHA256>.isValidAuthenticationCode(
            proofBytes,
            authenticating: transcript,
            using: derivedKey(capability: capability, domain: serverKeyDomain)
        )
    }

    /// Creates a signed, allow-listed error after client proof succeeds.
    public static func serverErrorProof(
        capability: String,
        nonce: Data,
        challenge: Data,
        processID: pid_t,
        processStartAbsoluteTime: UInt64,
        code: String
    ) -> String? {
        guard capabilityNonce(from: capability) == nonce,
              let transcript = serverErrorTranscript(
                  nonce: nonce,
                  challenge: challenge,
                  processID: processID,
                  processStartAbsoluteTime: processStartAbsoluteTime,
                  code: code
              ) else {
            return nil
        }
        return serverHMAC(capability: capability, message: transcript)
    }

    /// Verifies a signed, allow-listed error before the CLI maps its code.
    public static func verifiesServerErrorProof(
        _ proof: String,
        capability: String,
        nonce: Data,
        challenge: Data,
        processID: pid_t,
        processStartAbsoluteTime: UInt64,
        code: String
    ) -> Bool {
        guard capabilityNonce(from: capability) == nonce,
              let proofBytes = decodeLowercaseHex32(proof),
              let transcript = serverErrorTranscript(
                  nonce: nonce,
                  challenge: challenge,
                  processID: processID,
                  processStartAbsoluteTime: processStartAbsoluteTime,
                  code: code
              ) else {
            return false
        }
        return HMAC<SHA256>.isValidAuthenticationCode(
            proofBytes,
            authenticating: transcript,
            using: derivedKey(capability: capability, domain: serverKeyDomain)
        )
    }

    static func clientTranscript(
        nonce: Data,
        challenge: Data,
        processID: pid_t,
        processStartAbsoluteTime: UInt64
    ) -> Data? {
        guard nonce.count == byteCount,
              challenge.count == byteCount,
              processID > 0,
              processStartAbsoluteTime > 0 else {
            return nil
        }
        var transcript = requestDomain
        appendBigEndian(proofVersion, to: &transcript)
        appendBigEndian(UInt32(protocolVersion), to: &transcript)
        appendLengthPrefixedUTF8(requestID, to: &transcript)
        appendLengthPrefixedUTF8(method, to: &transcript)
        appendBigEndian(UInt32(processID), to: &transcript)
        appendBigEndian(processStartAbsoluteTime, to: &transcript)
        transcript.append(nonce)
        transcript.append(challenge)
        return transcript
    }

    private static func serverSuccessTranscript(
        nonce: Data,
        challenge: Data,
        processID: pid_t,
        processStartAbsoluteTime: UInt64,
        teamBinding: String
    ) -> Data? {
        guard let clientTranscript = clientTranscript(
            nonce: nonce,
            challenge: challenge,
            processID: processID,
            processStartAbsoluteTime: processStartAbsoluteTime
        ), let teamBindingBytes = decodeLowercaseHex32(teamBinding) else {
            return nil
        }
        var result = resultDomain
        result.append(1)
        appendBigEndian(UInt32(protocolVersion), to: &result)
        result.append(1)
        result.append(teamBindingBytes)
        var transcript = clientTranscript
        transcript.append(result)
        return transcript
    }

    private static func serverErrorTranscript(
        nonce: Data,
        challenge: Data,
        processID: pid_t,
        processStartAbsoluteTime: UInt64,
        code: String
    ) -> Data? {
        guard signedErrorCodes.contains(code),
              code.utf8.allSatisfy({ $0 < 0x80 }),
              let clientTranscript = clientTranscript(
                  nonce: nonce,
                  challenge: challenge,
                  processID: processID,
                  processStartAbsoluteTime: processStartAbsoluteTime
              ) else {
            return nil
        }
        var result = resultDomain
        result.append(0)
        appendLengthPrefixedUTF8(code, to: &result)
        var transcript = clientTranscript
        transcript.append(result)
        return transcript
    }

    private static func appendLengthPrefixedUTF8(
        _ value: String,
        to data: inout Data
    ) {
        let bytes = Data(value.utf8)
        appendBigEndian(UInt32(bytes.count), to: &data)
        data.append(bytes)
    }

    private static func appendBigEndian<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func hmacHex(
        capability: String,
        message: Data
    ) -> String {
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: message,
            using: derivedKey(capability: capability, domain: clientKeyDomain)
        )
        return Data(authenticationCode).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func serverHMAC(
        capability: String,
        message: Data
    ) -> String {
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: message,
            using: derivedKey(capability: capability, domain: serverKeyDomain)
        )
        return Data(authenticationCode).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func derivedKey(
        capability: String,
        domain: Data
    ) -> SymmetricKey {
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: domain,
            using: SymmetricKey(data: Data(capability.utf8))
        )
        return SymmetricKey(data: Data(authenticationCode))
    }

    private static func decodeLowercaseHex32(_ value: String) -> Data? {
        let bytes = Array(value.utf8)
        guard bytes.count == byteCount * 2 else { return nil }
        var result = Data()
        result.reserveCapacity(byteCount)
        var index = 0
        while index < bytes.count {
            guard let high = hexNibble(bytes[index]),
                  let low = hexNibble(bytes[index + 1]) else {
                return nil
            }
            result.append((high << 4) | low)
            index += 2
        }
        return result
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 97...102: byte - 87
        default: nil
        }
    }
}
