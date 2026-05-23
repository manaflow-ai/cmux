import CryptoKit
import Darwin
import Foundation
import os
import Security

private let helperLogger = Logger(subsystem: "com.cmuxterm.sudo-helper", category: "daemon")
private let socketPath = "/var/run/cmux-sudo-helper.sock"
private let secureSearchPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
private let deniedRootExecutableNames: Set<String> = [
    "bash", "csh", "dash", "env", "fish", "ksh", "login", "sh", "su", "sudo", "tcsh", "zsh",
]
private let maxCapturedOutputBytes = 2 * 1024 * 1024
private let maxCommandRuntimeSeconds = 10 * 60
private let allowedBundleIdentifiers: Set<String> = [
    "com.cmuxterm.app",
    "com.cmuxterm.app.debug",
    "com.cmuxterm.app.nightly",
    "com.cmuxterm.app.staging",
]
private let allowedBundleIdentifierPrefixes = [
    "com.cmuxterm.app.debug.",
    "com.cmuxterm.app.nightly.",
    "com.cmuxterm.app.staging.",
]
private let allowedTeamIdentifiers: Set<String> = [
    "7WLXT3NR37",
]
private let maxEnvelopeAge: TimeInterval = 5 * 60
private let maxSeenRequestIDs = 4096

struct HelperError: LocalizedError {
    let code: String
    let message: String

    var errorDescription: String? { message }
}

struct PeerIdentity {
    let pid: pid_t
    let uid: uid_t
    let auditTokenData: Data
}

struct HelperEnvelope {
    let payload: [String: Any]
    let signature: String
    let publicKey: String
}

@main
enum CMUXSudoHelper {
    private static var seenRequestIDs: [String: Date] = [:]
    private static let seenRequestIDLock = NSLock()
    private static let clientQueue = DispatchQueue(label: "com.cmuxterm.sudo-helper.clients", attributes: .concurrent)

    static func main() {
        signal(SIGPIPE, SIG_IGN)
        do {
            try runServer()
        } catch {
            writeLog("fatal \(String(describing: error))")
            exit(1)
        }
    }

    private static func runServer() throws {
        let listener = try makeListener()
        defer {
            Darwin.close(listener)
            unlink(socketPath)
        }

        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                writeLog("accept_failed \(errnoMessage("accept"))")
                continue
            }
            clientQueue.async {
                handleClient(client)
            }
        }
    }

    private static func handleClient(_ client: Int32) {
        defer { Darwin.close(client) }
        let response: [String: Any]
        do {
            try configureNoSigPipe(client)
            let peer = try peerIdentity(for: client)
            try validatePeerApp(peer: peer)
            let envelope = try readEnvelope(from: client)
            try verifyEnvelope(envelope)
            response = try execute(envelope: envelope, peer: peer)
        } catch let error as HelperError {
            response = [
                "status": "helper_error",
                "exit_code": NSNull(),
                "stdout": "",
                "stderr": "",
                "error_code": error.code,
                "message": error.message,
            ]
        } catch {
            writeLog("unexpected \(String(describing: error))")
            response = [
                "status": "helper_error",
                "exit_code": NSNull(),
                "stdout": "",
                "stderr": "",
                "error_code": "unexpected_error",
                "message": "The sudo helper failed before running the command",
            ]
        }
        do {
            try writeJSONLine(response, to: client)
        } catch {
            writeLog("write_response_failed \(String(describing: error))")
        }
    }

    private static func makeListener() throws -> Int32 {
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw HelperError(code: "socket_failed", message: errnoMessage("socket"))
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8) + [0]
        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        withUnsafeMutableBytes(of: &address) { rawAddress in
            pathBytes.withUnsafeBytes { rawPath in
                rawAddress.baseAddress?
                    .advanced(by: pathOffset)
                    .copyMemory(from: rawPath.baseAddress!, byteCount: pathBytes.count)
            }
        }

        let length = socklen_t(pathOffset + pathBytes.count)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length)
            }
        }
        guard bound == 0 else {
            let message = errnoMessage("bind")
            Darwin.close(fd)
            throw HelperError(code: "bind_failed", message: message)
        }

        guard chown(socketPath, 0, 80) == 0 else {
            let message = errnoMessage("chown")
            Darwin.close(fd)
            throw HelperError(code: "socket_chown_failed", message: message)
        }
        guard chmod(socketPath, 0o660) == 0 else {
            let message = errnoMessage("chmod")
            Darwin.close(fd)
            throw HelperError(code: "socket_chmod_failed", message: message)
        }

        guard listen(fd, 8) == 0 else {
            let message = errnoMessage("listen")
            Darwin.close(fd)
            throw HelperError(code: "listen_failed", message: message)
        }
        return fd
    }

    private static func peerIdentity(for fd: Int32) throws -> PeerIdentity {
        var auditToken = audit_token_t()
        var auditTokenSize = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &auditToken, &auditTokenSize) == 0 else {
            throw HelperError(code: "peer_audit_unavailable", message: errnoMessage("LOCAL_PEERTOKEN"))
        }
        let pid = audit_token_to_pid(auditToken)
        let uid = audit_token_to_euid(auditToken)
        guard pid > 0 else {
            throw HelperError(code: "peer_pid_unavailable", message: "Peer audit token did not include a process id")
        }
        let auditTokenData = withUnsafeBytes(of: auditToken) { Data($0) }
        return PeerIdentity(pid: pid, uid: uid, auditTokenData: auditTokenData)
    }

    private static func validatePeerApp(peer: PeerIdentity) throws {
        let attributes = [String(kSecGuestAttributeAudit): peer.auditTokenData] as CFDictionary
        var code: SecCode?
        let guestStatus = SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code)
        guard guestStatus == errSecSuccess, let code else {
            throw HelperError(code: "peer_code_unavailable", message: "Unable to inspect the requesting app signature")
        }

        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            throw HelperError(code: "peer_code_unavailable", message: "Unable to inspect the requesting app static signature")
        }

        var rawInfo: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInfo
        )
        guard infoStatus == errSecSuccess,
              let info = rawInfo as? [String: Any],
              let identifier = info[kSecCodeInfoIdentifier as String] as? String else {
            throw HelperError(code: "peer_code_rejected", message: "Requesting process is not a cmux app")
        }

        let identifierAllowed = allowedBundleIdentifiers.contains(identifier)
            || allowedBundleIdentifierPrefixes.contains { identifier.hasPrefix($0) }
        guard identifierAllowed else {
            throw HelperError(code: "peer_code_rejected", message: "Requesting process is not a cmux app")
        }

        guard let teamIdentifier = info[kSecCodeInfoTeamIdentifier as String] as? String,
              allowedTeamIdentifiers.contains(teamIdentifier) else {
            throw HelperError(code: "peer_code_rejected", message: "Requesting process is not signed by Manaflow")
        }

        let requirementText = #"identifier "\#(identifier)" and anchor apple generic and certificate leaf[subject.OU] = "\#(teamIdentifier)""# as CFString
        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(requirementText, SecCSFlags(), &requirement)
        guard requirementStatus == errSecSuccess, let requirement else {
            throw HelperError(code: "peer_code_rejected", message: "Unable to build cmux code-signing requirement")
        }

        var errors: Unmanaged<CFError>?
        let checkStatus = SecStaticCodeCheckValidityWithErrors(staticCode, SecCSFlags(), requirement, &errors)
        guard checkStatus == errSecSuccess else {
            let detail = errors?.takeRetainedValue().localizedDescription ?? "Requesting process signature does not match cmux"
            throw HelperError(code: "peer_code_rejected", message: detail)
        }
    }

    private static func readEnvelope(from fd: Int32) throws -> HelperEnvelope {
        let data = try readLineData(from: fd)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let signature = object["signature"] as? String,
              let publicKey = object["public_key"] as? String else {
            throw HelperError(code: "malformed_payload", message: "Helper request is malformed")
        }
        return HelperEnvelope(payload: payload, signature: signature, publicKey: publicKey)
    }

    private static func verifyEnvelope(_ envelope: HelperEnvelope) throws {
        guard let signatureData = Data(base64Encoded: envelope.signature),
              let publicKeyData = Data(base64Encoded: envelope.publicKey),
              let payloadData = try? canonicalJSONData(envelope.payload),
              let publicKey = try? P256.Signing.PublicKey(derRepresentation: publicKeyData),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData),
              publicKey.isValidSignature(signature, for: payloadData) else {
            throw HelperError(code: "bad_signature", message: "Helper request signature is invalid")
        }
        guard let requestID = envelope.payload["request_id"] as? String,
              !requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HelperError(code: "missing_request_id", message: "Helper request is missing a request id")
        }
        guard let createdAtRaw = envelope.payload["created_at"] as? String,
              let createdAt = parseISO8601(createdAtRaw),
              abs(Date().timeIntervalSince(createdAt)) <= maxEnvelopeAge else {
            throw HelperError(code: "stale_request", message: "Helper request has expired")
        }
        try rememberRequestID(requestID, createdAt: createdAt)
    }

    private static func rememberRequestID(_ requestID: String, createdAt: Date) throws {
        seenRequestIDLock.lock()
        defer { seenRequestIDLock.unlock() }
        pruneSeenRequestIDs(now: Date())
        guard seenRequestIDs[requestID] == nil else {
            throw HelperError(code: "replayed_request", message: "Helper request was already used")
        }
        if seenRequestIDs.count >= maxSeenRequestIDs {
            throw HelperError(
                code: "replay_cache_full",
                message: String(
                    localized: "sudo.helper.replayCacheFull",
                    defaultValue: "The sudo helper is temporarily busy validating requests. Retry shortly."
                )
            )
        }
        seenRequestIDs[requestID] = createdAt
    }

    private static func pruneSeenRequestIDs(now: Date) {
        seenRequestIDs = seenRequestIDs.filter { _, createdAt in
            now.timeIntervalSince(createdAt) <= maxEnvelopeAge
        }
    }

    private static func execute(envelope: HelperEnvelope, peer: PeerIdentity) throws -> [String: Any] {
        guard let argv = envelope.payload["argv"] as? [String], !argv.isEmpty else {
            throw HelperError(code: "missing_argv", message: "Helper request has no command")
        }
        guard let requesterUID = intValue(envelope.payload["requester_uid"]),
              requesterUID == Int(peer.uid) else {
            throw HelperError(code: "uid_mismatch", message: "Requester uid does not match the cmux app uid")
        }
        guard let cwd = envelope.payload["cwd"] as? String,
              !cwd.isEmpty,
              !cwd.contains("\0") else {
            throw HelperError(code: "missing_cwd", message: "Helper request is missing a working directory")
        }
        let timeoutSeconds = min(
            max(intValue(envelope.payload["timeout_seconds"]) ?? maxCommandRuntimeSeconds, 1),
            maxCommandRuntimeSeconds
        )
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw HelperError(code: "cwd_unavailable", message: "Working directory is unavailable")
        }

        let executable = try resolveExecutable(argv[0])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        process.environment = ["PATH": secureSearchPath.joined(separator: ":")]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdout = OutputCollector()
        let stderr = OutputCollector()
        let stdinHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        defer { try? stdinHandle.close() }
        stdoutPipe.fileHandleForReading.readabilityHandler = { stdout.append($0.availableData) }
        stderrPipe.fileHandleForReading.readabilityHandler = { stderr.append($0.availableData) }
        process.standardInput = stdinHandle
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }

        try process.run()
        let timedOut = finished.wait(timeout: .now() + .seconds(timeoutSeconds)) == .timedOut
        if timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + .seconds(2)) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + .seconds(2))
            }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdout.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        stderr.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

        if timedOut {
            return [
                "status": "command_timeout",
                "exit_code": 124,
                "stdout": stdout.stringValue,
                "stderr": stderr.stringValue,
                "error_code": "command_timeout",
                "message": "Sudo command exceeded the cmux timeout",
            ]
        }

        return [
            "status": "completed",
            "exit_code": Int(process.terminationStatus),
            "stdout": stdout.stringValue,
            "stderr": stderr.stringValue,
            "error_code": NSNull(),
            "message": NSNull(),
        ]
    }

    private static func resolveExecutable(_ command: String) throws -> String {
        guard !command.contains("\0"), !command.isEmpty else {
            throw HelperError(code: "invalid_command", message: "Command is empty or contains NUL")
        }
        if command.contains("/") {
            guard command.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: command) else {
                throw HelperError(code: "command_not_executable", message: "Command is not an executable absolute path")
            }
            return try allowedRootExecutablePath(command)
        }

        for directory in secureSearchPath {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(command).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return try allowedRootExecutablePath(candidate)
            }
        }
        throw HelperError(code: "command_not_found", message: "Command was not found in the helper search path")
    }

    private static func allowedRootExecutablePath(_ path: String) throws -> String {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let executableName = URL(fileURLWithPath: resolved).lastPathComponent.lowercased()
        guard !deniedRootExecutableNames.contains(executableName) else {
            throw HelperError(
                code: "command_rejected",
                message: String(
                    localized: "sudo.helper.shellRejected",
                    defaultValue: "cmux sudo will not run shell, sudo, su, env, or login executables as root."
                )
            )
        }
        return resolved
    }

    private static func readLineData(from fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw HelperError(code: "read_failed", message: errnoMessage("read"))
            }
            if count == 0 {
                return data
            }
            let chunk = buffer.prefix(Int(count))
            if let newlineIndex = chunk.firstIndex(of: 0x0a) {
                data.append(contentsOf: chunk[..<newlineIndex])
                if data.count > maxCapturedOutputBytes {
                    throw HelperError(code: "request_too_large", message: "Helper request is too large")
                }
                return data
            }
            data.append(contentsOf: chunk)
            if data.count > maxCapturedOutputBytes {
                throw HelperError(code: "request_too_large", message: "Helper request is too large")
            }
        }
    }

    private static func writeJSONLine(_ object: [String: Any], to fd: Int32) throws {
        var data = try canonicalJSONData(object)
        data.append(0x0a)
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(fd, baseAddress.advanced(by: offset), data.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw HelperError(code: "write_failed", message: errnoMessage("write"))
                }
                guard written > 0 else {
                    throw HelperError(code: "write_failed", message: "Client socket closed")
                }
                offset += written
            }
        }
    }

    private static func configureNoSigPipe(_ fd: Int32) throws {
#if os(macOS)
        var noSigPipe: Int32 = 1
        let result = withUnsafePointer(to: &noSigPipe) { pointer in
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, pointer, socklen_t(MemoryLayout<Int32>.size))
        }
        guard result == 0 else {
            throw HelperError(code: "setsockopt_failed", message: errnoMessage("setsockopt(SO_NOSIGPIPE)"))
        }
#else
        _ = fd
#endif
    }

    private static func canonicalJSONData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func parseISO8601(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func errnoMessage(_ operation: String) -> String {
        "\(operation) failed: \(String(cString: strerror(errno)))"
    }

    private static func writeLog(_ message: String) {
        helperLogger.error("\(message, privacy: .private)")
    }
}

private final class OutputCollector {
    private let lock = NSLock()
    private var data = Data()

    var stringValue: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard data.count < maxCapturedOutputBytes else { return }
        data.append(chunk.prefix(maxCapturedOutputBytes - data.count))
    }
}
