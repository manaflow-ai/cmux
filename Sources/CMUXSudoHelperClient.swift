import CryptoKit
import Darwin
import Foundation
import os

nonisolated private let cmuxSudoHelperClientLogger = Logger(subsystem: "com.cmuxterm.app", category: "sudo-helper-client")

struct CMUXSudoHelperExecutionResult: Sendable {
    let status: String
    let exitCode: Int32?
    let stdout: String?
    let stderr: String?
    let errorCode: String?
    let message: String?
}

struct CMUXSudoSignedHelperEnvelope: @unchecked Sendable {
    let payload: [String: Any]
    let signatureBase64: String
    let publicKeyBase64: String

    var jsonObject: [String: Any] {
        [
            "version": 1,
            "payload": payload,
            "signature": signatureBase64,
            "public_key": publicKeyBase64,
        ]
    }
}

enum CMUXSudoHelperSignatureVerifier {
    static func verify(_ envelope: CMUXSudoSignedHelperEnvelope) -> Bool {
        guard let signatureData = Data(base64Encoded: envelope.signatureBase64),
              let publicKeyData = Data(base64Encoded: envelope.publicKeyBase64),
              let payloadData = try? CMUXSudoHelperClient.canonicalJSONData(envelope.payload),
              let publicKey = try? P256.Signing.PublicKey(derRepresentation: publicKeyData),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData) else {
            return false
        }
        return publicKey.isValidSignature(signature, for: payloadData)
    }
}

enum CMUXSudoHelperClient {
    static let helperSocketPath = "/var/run/cmux-sudo-helper.sock"
    private static let maxHelperResponseBytes = 2 * 1024 * 1024
    private static let helperSocketTimeoutSeconds = 30
    private static let sessionSigningKey = P256.Signing.PrivateKey()

    static func signedEnvelope(for request: CMUXSudoCommandRequest) throws -> CMUXSudoSignedHelperEnvelope {
        let payload: [String: Any] = [
            "request_id": request.requestID,
            "argv": request.argv,
            "command_display": request.displayCommand,
            "workspace_id": request.workspaceID.uuidString,
            "surface_id": request.surfaceID.uuidString,
            "requester_uid": Int(request.callerUID),
            "requester_pid": Int(request.callerPID),
            "cwd": request.cwd as Any? ?? NSNull(),
            "created_at": CMUXSudoAuditLogger.iso8601(Date()),
        ]
        let data = try canonicalJSONData(payload)
        let signature = try sessionSigningKey.signature(for: data)
        return CMUXSudoSignedHelperEnvelope(
            payload: payload,
            signatureBase64: signature.derRepresentation.base64EncodedString(),
            publicKeyBase64: sessionSigningKey.publicKey.derRepresentation.base64EncodedString()
        )
    }

    static func execute(_ envelope: CMUXSudoSignedHelperEnvelope) -> CMUXSudoHelperExecutionResult {
#if DEBUG
        if let override = CMUXSudoTestHooks.helperOverride {
            return override(envelope)
        }
#endif
        let service = availability()
        guard service.available else {
            return .init(
                status: "helper_unavailable",
                exitCode: nil,
                stdout: nil,
                stderr: nil,
                errorCode: service.errorCode ?? "helper_unavailable",
                message: service.message
            )
        }

        do {
            return try executeAgainstSocket(path: helperSocketPath, envelope: envelope)
        } catch {
            cmuxSudoHelperClientLogger.error("sudo.helper.transport.failed error=\(String(describing: error), privacy: .private)")
            return .init(
                status: "helper_unavailable",
                exitCode: nil,
                stdout: nil,
                stderr: nil,
                errorCode: "helper_transport_error",
                message: String(
                    localized: "sudo.helper.clientUnavailable",
                    defaultValue: "The cmux sudo helper client could not reach the privileged helper. No command was run."
                )
            )
        }
    }

    static func availability() -> CMUXSudoHelperServiceResult {
#if DEBUG
        if let override = CMUXSudoTestHooks.helperAvailabilityOverride {
            return override()
        }
#endif
        let service = CMUXSudoHelperService.ensureRegistered()
        guard service.available else {
            return service
        }

        guard FileManager.default.fileExists(atPath: helperSocketPath) else {
            return .unavailable(
                errorCode: "helper_unavailable",
                message: String(
                    localized: "sudo.helper.unavailable",
                    defaultValue: "The cmux sudo helper is not installed or enabled. No command was run."
                )
            )
        }

        return .available
    }

    static func canonicalJSONData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func executeAgainstSocket(
        path: String,
        envelope: CMUXSudoSignedHelperEnvelope
    ) throws -> CMUXSudoHelperExecutionResult {
        let fd = try connectUnixSocket(path: path)
        defer { Darwin.close(fd) }

        var request = try canonicalJSONData(envelope.jsonObject)
        request.append(0x0a)
        try writeAll(request, to: fd)
        Darwin.shutdown(fd, SHUT_WR)

        let responseData = try readResponse(from: fd)
        guard !responseData.isEmpty else {
            throw HelperTransportError("helper returned an empty response")
        }
        guard let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw HelperTransportError("helper returned malformed JSON")
        }
        return .init(
            status: object["status"] as? String ?? "helper_error",
            exitCode: int32Value(object["exit_code"]),
            stdout: object["stdout"] as? String,
            stderr: object["stderr"] as? String,
            errorCode: object["error_code"] as? String,
            message: object["message"] as? String
        )
    }

    private static func connectUnixSocket(path: String) throws -> Int32 {
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw HelperTransportError("helper socket path is too long")
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw HelperTransportError(lastErrnoMessage("socket"))
        }
        do {
            try configureTimeouts(fd)
        } catch {
            Darwin.close(fd)
            throw error
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        withUnsafeMutableBytes(of: &address) { rawAddress in
            pathBytes.withUnsafeBytes { rawPath in
                rawAddress.baseAddress?
                    .advanced(by: pathOffset)
                    .copyMemory(from: rawPath.baseAddress!, byteCount: pathBytes.count)
            }
        }

        let length = socklen_t(
            (MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0)
            + path.utf8.count
            + 1
        )
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, length)
            }
        }
        guard connected == 0 else {
            let message = lastErrnoMessage("connect")
            Darwin.close(fd)
            throw HelperTransportError(message)
        }
        return fd
    }

    private static func configureTimeouts(_ fd: Int32) throws {
        var timeout = timeval(tv_sec: helperSocketTimeoutSeconds, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        let sendResult = withUnsafePointer(to: &timeout) { pointer in
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, pointer, size)
        }
        guard sendResult == 0 else {
            throw HelperTransportError(lastErrnoMessage("setsockopt(SO_SNDTIMEO)"))
        }
        let receiveResult = withUnsafePointer(to: &timeout) { pointer in
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, pointer, size)
        }
        guard receiveResult == 0 else {
            throw HelperTransportError(lastErrnoMessage("setsockopt(SO_RCVTIMEO)"))
        }
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(
                    fd,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        throw HelperTransportError("helper socket write timed out")
                    }
                    throw HelperTransportError(lastErrnoMessage("write"))
                }
                guard written > 0 else {
                    throw HelperTransportError("helper socket closed while writing request")
                }
                offset += written
            }
        }
    }

    private static func readResponse(from fd: Int32) throws -> Data {
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw HelperTransportError("helper socket read timed out")
                }
                throw HelperTransportError(lastErrnoMessage("read"))
            }
            if count == 0 {
                return response
            }
            response.append(contentsOf: buffer.prefix(Int(count)))
            if response.count > maxHelperResponseBytes {
                throw HelperTransportError("helper response exceeded \(maxHelperResponseBytes) bytes")
            }
        }
    }

    private static func int32Value(_ value: Any?) -> Int32? {
        func checked(_ value: Int64) -> Int32? {
            guard value >= Int64(Int32.min), value <= Int64(Int32.max) else { return nil }
            return Int32(value)
        }
        if let value = value as? Int { return checked(Int64(value)) }
        if let value = value as? NSNumber { return checked(value.int64Value) }
        if let value = value as? String,
           let parsed = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return checked(parsed)
        }
        return nil
    }

    private static func lastErrnoMessage(_ operation: String) -> String {
        "\(operation) failed: \(String(cString: strerror(errno)))"
    }

    private struct HelperTransportError: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}
