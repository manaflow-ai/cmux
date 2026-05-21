import AppKit
import CryptoKit
import Darwin
import Foundation
import LocalAuthentication

struct CMUXSudoCommandRequest: Sendable {
    let requestID: String
    let argv: [String]
    let displayCommand: String
    let workspaceID: UUID
    let surfaceID: UUID
    let callerPID: pid_t
    let callerUID: uid_t
    let cwd: String?

    static func parse(params: [String: Any]) -> Result<CMUXSudoCommandRequest, CMUXSudoRequestError> {
        let requestID = (params["request_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveRequestID = requestID?.isEmpty == false ? requestID! : UUID().uuidString

        guard let rawArgv = params["argv"] as? [Any], !rawArgv.isEmpty else {
            return .failure(.invalidParams(String(localized: "sudo.error.argvArray", defaultValue: "argv must be a non-empty string array")))
        }
        var argv: [String] = []
        argv.reserveCapacity(rawArgv.count)
        for value in rawArgv {
            guard let arg = value as? String, !arg.contains("\0") else {
                return .failure(.invalidParams(String(localized: "sudo.error.argvStringsNoNUL", defaultValue: "argv must contain only strings without NUL bytes")))
            }
            argv.append(arg)
        }
        guard argv.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return .failure(.invalidParams(String(localized: "sudo.error.argvExecutable", defaultValue: "argv[0] must be a command path or executable name")))
        }

        guard let workspaceRaw = params["workspace_id"] as? String,
              let workspaceID = UUID(uuidString: workspaceRaw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure(.invalidParams(String(localized: "sudo.error.workspaceUUID", defaultValue: "workspace_id must be a UUID")))
        }
        guard let surfaceRaw = params["surface_id"] as? String,
              let surfaceID = UUID(uuidString: surfaceRaw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure(.invalidParams(String(localized: "sudo.error.surfaceUUID", defaultValue: "surface_id must be a UUID")))
        }
        guard let callerPID = pidValue(params["caller_pid"]), callerPID > 0 else {
            return .failure(.invalidParams(String(localized: "sudo.error.callerPID", defaultValue: "caller_pid must be a positive integer")))
        }
        guard let callerUID = uidValue(params["caller_uid"]) else {
            return .failure(.invalidParams(String(localized: "sudo.error.callerUID", defaultValue: "caller_uid must be an integer")))
        }

        let cwd = (params["cwd"] as? String).flatMap { raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.contains("\0") else { return nil }
            return trimmed
        }

        return .success(
            CMUXSudoCommandRequest(
                requestID: effectiveRequestID,
                argv: argv,
                displayCommand: CMUXSudoCommandLine.display(argv),
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                callerPID: callerPID,
                callerUID: callerUID,
                cwd: cwd
            )
        )
    }

    private static func pidValue(_ value: Any?) -> pid_t? {
        if let value = value as? Int { return pid_t(value) }
        if let value = value as? NSNumber { return pid_t(value.int32Value) }
        if let value = value as? String, let parsed = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return pid_t(parsed)
        }
        return nil
    }

    private static func uidValue(_ value: Any?) -> uid_t? {
        if let value = value as? UInt { return uid_t(value) }
        if let value = value as? Int, value >= 0 { return uid_t(value) }
        if let value = value as? NSNumber { return uid_t(value.uint32Value) }
        if let value = value as? String, let parsed = UInt32(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return uid_t(parsed)
        }
        return nil
    }
}

enum CMUXSudoRequestError: Error, Sendable {
    case invalidParams(String)
    case accessDenied(String)
    case authenticationDenied(String)
    case auditUnavailable(String)
    case helperUnavailable(String)

    var code: String {
        switch self {
        case .invalidParams: return "invalid_params"
        case .accessDenied: return "access_denied"
        case .authenticationDenied: return "authentication_denied"
        case .auditUnavailable: return "audit_unavailable"
        case .helperUnavailable: return "helper_unavailable"
        }
    }

    var message: String {
        switch self {
        case .invalidParams(let message),
             .accessDenied(let message),
             .authenticationDenied(let message),
             .auditUnavailable(let message),
             .helperUnavailable(let message):
            return message
        }
    }
}

enum CMUXSudoCommandLine {
    static func display(_ argv: [String]) -> String {
        argv.map(shellQuoted).joined(separator: " ")
    }

    private static func shellQuoted(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-./:=,@%")
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct CMUXSudoCallerValidationResult: Sendable {
    let allowed: Bool
    let reason: String?
}

enum CMUXSudoCallerValidator {
    static func validate(
        request: CMUXSudoCommandRequest,
        peerIdentity: CMUXSocketPeerIdentity,
        isDescendant: (pid_t) -> Bool,
        processArguments: (pid_t) -> CmuxTopProcessArguments?,
        surfaceExists: (UUID, UUID) -> Bool
    ) -> CMUXSudoCallerValidationResult {
        guard let peerPID = peerIdentity.pid, peerPID > 0 else {
            return .init(allowed: false, reason: String(localized: "sudo.error.peerPIDUnavailable", defaultValue: "socket peer pid is unavailable"))
        }
        guard let peerUID = peerIdentity.uid else {
            return .init(allowed: false, reason: String(localized: "sudo.error.peerUIDUnavailable", defaultValue: "socket peer uid is unavailable"))
        }
        guard peerPID == request.callerPID else {
            return .init(allowed: false, reason: String(localized: "sudo.error.pidMismatch", defaultValue: "caller_pid does not match socket peer pid"))
        }
        guard peerUID == request.callerUID, peerUID == getuid() else {
            return .init(allowed: false, reason: String(localized: "sudo.error.uidMismatch", defaultValue: "caller_uid does not match socket peer uid"))
        }
        guard isDescendant(peerPID) else {
            return .init(allowed: false, reason: String(localized: "sudo.error.notCmuxChild", defaultValue: "requesting process is not a cmux child"))
        }
        guard let process = processArguments(peerPID),
              let scope = CmuxTopProcessSnapshot.cmuxScope(
                arguments: process.arguments,
                environment: process.environment
              ) else {
            return .init(allowed: false, reason: String(localized: "sudo.error.noScope", defaultValue: "requesting process has no cmux terminal scope"))
        }
        guard scope.workspaceID == request.workspaceID, scope.surfaceID == request.surfaceID else {
            return .init(allowed: false, reason: String(localized: "sudo.error.scopeMismatch", defaultValue: "request scope does not match requesting process environment"))
        }
        guard surfaceExists(request.workspaceID, request.surfaceID) else {
            return .init(allowed: false, reason: String(localized: "sudo.error.surfaceInactive", defaultValue: "workspace or terminal surface is not active"))
        }
        return .init(allowed: true, reason: nil)
    }
}

struct CMUXSudoApprovalResult: Sendable {
    let approved: Bool
    let reason: String?
}

enum CMUXSudoApprovalPresenter {
    static func requestApprovalSync(_ request: CMUXSudoCommandRequest) -> CMUXSudoApprovalResult {
#if DEBUG
        if let override = CMUXSudoTestHooks.approvalOverride {
            return override(request)
        }
#endif
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: CMUXSudoApprovalResult?

        Task { @MainActor in
            let alert = NSAlert()
            alert.messageText = String(
                localized: "sudo.prompt.title",
                defaultValue: "Approve sudo command?"
            )
            alert.informativeText = String(
                localized: "sudo.prompt.message",
                defaultValue: "cmux will authenticate you before sending this exact command to the privileged helper."
            )
            alert.addButton(withTitle: String(localized: "sudo.prompt.authenticate", defaultValue: "Authenticate"))
            alert.addButton(withTitle: String(localized: "sudo.prompt.deny", defaultValue: "Deny"))
            alert.accessoryView = commandAccessoryView(for: request.displayCommand)

            guard alert.runModal() == .alertFirstButtonReturn else {
                result = .init(
                    approved: false,
                    reason: String(localized: "sudo.denied.byUser", defaultValue: "User denied the sudo request")
                )
                semaphore.signal()
                return
            }

            let context = LAContext()
            context.localizedCancelTitle = String(localized: "sudo.auth.cancel", defaultValue: "Cancel")

            var evaluationError: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evaluationError) else {
                result = .init(
                    approved: false,
                    reason: evaluationError?.localizedDescription
                    ?? String(localized: "sudo.auth.unavailable", defaultValue: "Device owner authentication is unavailable")
                )
                semaphore.signal()
                return
            }

            let reasonFormat = String(
                localized: "sudo.auth.reason",
                defaultValue: "Approve cmux sudo command: %@"
            )
            let reason = String(format: reasonFormat, request.displayCommand)
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                result = .init(
                    approved: success,
                    reason: success ? nil : (
                        error?.localizedDescription
                        ?? String(localized: "sudo.auth.failed", defaultValue: "Authentication failed")
                    )
                )
                semaphore.signal()
            }
        }

        semaphore.wait()
        return result ?? .init(
            approved: false,
            reason: String(localized: "sudo.auth.failed", defaultValue: "Authentication failed")
        )
    }

    @MainActor
    private static func commandAccessoryView(for command: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: String(localized: "sudo.prompt.command", defaultValue: "Command"))
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        let commandField = NSTextField(wrappingLabelWithString: command)
        commandField.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        commandField.textColor = .labelColor
        commandField.maximumNumberOfLines = 6
        commandField.lineBreakMode = .byTruncatingMiddle
        commandField.widthAnchor.constraint(equalToConstant: 520).isActive = true

        stack.addArrangedSubview(label)
        stack.addArrangedSubview(commandField)
        return stack
    }
}

struct CMUXSudoHelperExecutionResult: Sendable {
    let status: String
    let exitCode: Int32?
    let stdout: String?
    let stderr: String?
    let errorCode: String?
    let message: String?
}

struct CMUXSudoSignedHelperEnvelope {
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
        guard FileManager.default.fileExists(atPath: helperSocketPath) else {
            return .init(
                status: "helper_unavailable",
                exitCode: nil,
                stdout: nil,
                stderr: nil,
                errorCode: "helper_unavailable",
                message: String(
                    localized: "sudo.helper.unavailable",
                    defaultValue: "The cmux sudo helper is not installed or enabled. No command was run."
                )
            )
        }

        do {
            return try executeAgainstSocket(path: helperSocketPath, envelope: envelope)
        } catch {
            return .init(
                status: "helper_unavailable",
                exitCode: nil,
                stdout: nil,
                stderr: nil,
                errorCode: "helper_transport_error",
                message: String(
                    localized: "sudo.helper.clientUnavailable",
                    defaultValue: "The cmux sudo helper client could not reach the privileged helper. No command was run."
                ) + " \(error.localizedDescription)"
            )
        }
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
        if let value = value as? Int { return Int32(value) }
        if let value = value as? NSNumber { return value.int32Value }
        if let value = value as? String, let parsed = Int32(value) { return parsed }
        return nil
    }

    private static func lastErrnoMessage(_ operation: String) -> String {
        "\(operation) failed: \(String(cString: strerror(errno)))"
    }

    private struct HelperTransportError: LocalizedError {
        let message: String

        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? {
            message
        }
    }
}

struct CMUXSudoAuditRecord: Sendable {
    let requestID: String
    let timestamp: Date
    let workspaceID: UUID?
    let surfaceID: UUID?
    let requesterPID: pid_t?
    let requesterUID: uid_t?
    let command: [String]
    let commandDisplay: String
    let result: String
    let exitCode: Int32?
    let errorCode: String?
    let message: String?

    var jsonObject: [String: Any] {
        [
            "request_id": requestID,
            "timestamp": CMUXSudoAuditLogger.iso8601(timestamp),
            "workspace_id": workspaceID?.uuidString as Any? ?? NSNull(),
            "surface_id": surfaceID?.uuidString as Any? ?? NSNull(),
            "requester_pid": requesterPID.map { Int($0) } as Any? ?? NSNull(),
            "requester_uid": requesterUID.map { Int($0) } as Any? ?? NSNull(),
            "command": command,
            "command_display": commandDisplay,
            "result": result,
            "exit_code": exitCode.map { Int($0) } as Any? ?? NSNull(),
            "error_code": errorCode as Any? ?? NSNull(),
            "message": message as Any? ?? NSNull(),
        ]
    }
}

enum CMUXSudoAuditLogger {
    static let maxBytes: UInt64 = 10 * 1024 * 1024
    static let maxRotatedFiles = 5

    static var defaultLogURL: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("sudo-audit.jsonl", isDirectory: false)
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func ensureWritable(logURL: URL = defaultLogURL) throws {
        try prepareLogFile(logURL: logURL)
    }

    @discardableResult
    static func append(_ record: CMUXSudoAuditRecord, logURL: URL = defaultLogURL) throws -> [String: Any] {
        try prepareLogFile(logURL: logURL)
        try rotateIfNeeded(logURL: logURL)

        let previousHash = previousEntryHash(logURL: logURL)
        var object = record.jsonObject
        object["previous_sha256"] = previousHash as Any? ?? NSNull()
        let entryHash = try sha256Hex(canonicalJSONData(object))
        object["entry_sha256"] = entryHash

        var data = try canonicalJSONData(object)
        data.append(0x0a)

        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try setPrivatePermissions(logURL)
        return object
    }

    private static func prepareLogFile(logURL: URL) throws {
        let directory = logURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try setPrivatePermissions(logURL)
    }

    private static func setPrivatePermissions(_ logURL: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
    }

    private static func rotateIfNeeded(logURL: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
        guard let size = attributes[.size] as? NSNumber, size.uint64Value >= maxBytes else { return }

        let oldest = rotatedURL(logURL, index: maxRotatedFiles)
        if FileManager.default.fileExists(atPath: oldest.path) {
            try FileManager.default.removeItem(at: oldest)
        }
        for index in stride(from: maxRotatedFiles - 1, through: 1, by: -1) {
            let source = rotatedURL(logURL, index: index)
            let destination = rotatedURL(logURL, index: index + 1)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.moveItem(at: source, to: destination)
            }
        }
        let first = rotatedURL(logURL, index: 1)
        if FileManager.default.fileExists(atPath: first.path) {
            try FileManager.default.removeItem(at: first)
        }
        try FileManager.default.moveItem(at: logURL, to: first)
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }

    private static func rotatedURL(_ logURL: URL, index: Int) -> URL {
        URL(fileURLWithPath: "\(logURL.path).\(index)")
    }

    private static func previousEntryHash(logURL: URL) -> String? {
        guard let data = try? Data(contentsOf: logURL), !data.isEmpty else { return nil }
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        guard let last = lines.last,
              let lineData = String(last).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let hash = object["entry_sha256"] as? String,
              !hash.isEmpty else {
            return nil
        }
        return hash
    }

    private static func canonicalJSONData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension TerminalController {
    nonisolated func v2SudoRequestOnSocketWorker(params: [String: Any]) -> V2CallResult {
        let parsed = CMUXSudoCommandRequest.parse(params: params)
        guard case .success(let request) = parsed else {
            let message: String
            if case .failure(let error) = parsed {
                message = error.message
            } else {
                message = String(localized: "sudo.error.invalidRequest", defaultValue: "invalid sudo request")
            }
            return .err(code: "invalid_params", message: message, data: nil)
        }

        let peerIdentity = Self.currentSocketPeerIdentity()
        let validation = CMUXSudoCallerValidator.validate(
            request: request,
            peerIdentity: peerIdentity,
            isDescendant: { [weak self] pid in
#if DEBUG
                if let override = CMUXSudoTestHooks.isDescendantOverride {
                    return override(pid)
                }
#endif
                return self?.isDescendant(pid) ?? false
            },
            processArguments: { pid in
#if DEBUG
                if let override = CMUXSudoTestHooks.processArgumentsOverride {
                    return override(pid)
                }
#endif
                return CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: Int(pid))
            },
            surfaceExists: { [weak self] workspaceID, surfaceID in
#if DEBUG
                if let override = CMUXSudoTestHooks.surfaceExistsOverride {
                    return override(workspaceID, surfaceID)
                }
#endif
                return self?.v2SudoSurfaceExists(workspaceID: workspaceID, surfaceID: surfaceID) ?? false
            }
        )
        let auditLogURL = sudoAuditLogURL()

        guard validation.allowed else {
            _ = try? CMUXSudoAuditLogger.append(
                auditRecord(
                    request: request,
                    result: "rejected",
                    exitCode: nil,
                    errorCode: "access_denied",
                    message: validation.reason
                ),
                logURL: auditLogURL
            )
            return .err(
                code: "access_denied",
                message: validation.reason ?? String(localized: "sudo.error.rejected", defaultValue: "sudo request was rejected"),
                data: nil
            )
        }

        do {
            try CMUXSudoAuditLogger.ensureWritable(logURL: auditLogURL)
        } catch {
            return .err(
                code: "audit_unavailable",
                message: String(format: String(localized: "sudo.error.auditUnavailable", defaultValue: "sudo audit log is not writable: %@"), error.localizedDescription),
                data: nil
            )
        }

        let approval = CMUXSudoApprovalPresenter.requestApprovalSync(request)
        guard approval.approved else {
            _ = try? CMUXSudoAuditLogger.append(
                auditRecord(
                    request: request,
                    result: "denied",
                    exitCode: nil,
                    errorCode: "authentication_denied",
                    message: approval.reason
                ),
                logURL: auditLogURL
            )
            return .err(
                code: "authentication_denied",
                message: approval.reason ?? String(localized: "sudo.error.denied", defaultValue: "sudo request was denied"),
                data: nil
            )
        }

        let envelope: CMUXSudoSignedHelperEnvelope
        do {
            envelope = try CMUXSudoHelperClient.signedEnvelope(for: request)
        } catch {
            return .err(
                code: "signing_failed",
                message: String(format: String(localized: "sudo.error.signingFailed", defaultValue: "Failed to sign sudo helper request: %@"), error.localizedDescription),
                data: nil
            )
        }

        let execution = CMUXSudoHelperClient.execute(envelope)
        _ = try? CMUXSudoAuditLogger.append(
            auditRecord(
                request: request,
                result: execution.status,
                exitCode: execution.exitCode,
                errorCode: execution.errorCode,
                message: execution.message
            ),
            logURL: auditLogURL
        )

        guard execution.status == "completed" else {
            return .err(
                code: execution.errorCode ?? "helper_error",
                message: execution.message ?? String(localized: "sudo.error.helperFailed", defaultValue: "sudo helper failed"),
                data: [
                    "status": execution.status,
                    "exit_code": execution.exitCode as Any? ?? NSNull()
                ]
            )
        }

        return .ok([
            "status": execution.status,
            "exit_code": Int(execution.exitCode ?? 0),
            "stdout": execution.stdout as Any? ?? NSNull(),
            "stderr": execution.stderr as Any? ?? NSNull(),
            "audit_log": auditLogURL.path,
        ])
    }

    private nonisolated func sudoAuditLogURL() -> URL {
#if DEBUG
        if let override = CMUXSudoTestHooks.auditLogURLOverride {
            return override
        }
#endif
        return CMUXSudoAuditLogger.defaultLogURL
    }

    private nonisolated func v2SudoSurfaceExists(workspaceID: UUID, surfaceID: UUID) -> Bool {
        v2MainSync {
            guard let app = AppDelegate.shared else { return false }
            for summary in app.listMainWindowSummaries() {
                guard let tabManager = app.tabManagerFor(windowId: summary.windowId),
                      let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
                    continue
                }
                if workspace.terminalPanel(for: surfaceID) != nil {
                    return true
                }
            }
            return false
        }
    }

    private nonisolated func auditRecord(
        request: CMUXSudoCommandRequest,
        result: String,
        exitCode: Int32?,
        errorCode: String?,
        message: String?
    ) -> CMUXSudoAuditRecord {
        CMUXSudoAuditRecord(
            requestID: request.requestID,
            timestamp: Date(),
            workspaceID: request.workspaceID,
            surfaceID: request.surfaceID,
            requesterPID: request.callerPID,
            requesterUID: request.callerUID,
            command: request.argv,
            commandDisplay: request.displayCommand,
            result: result,
            exitCode: exitCode,
            errorCode: errorCode,
            message: message
        )
    }
}

#if DEBUG
enum CMUXSudoTestHooks {
    nonisolated(unsafe) static var approvalOverride: ((CMUXSudoCommandRequest) -> CMUXSudoApprovalResult)?
    nonisolated(unsafe) static var helperOverride: ((CMUXSudoSignedHelperEnvelope) -> CMUXSudoHelperExecutionResult)?
    nonisolated(unsafe) static var isDescendantOverride: ((pid_t) -> Bool)?
    nonisolated(unsafe) static var processArgumentsOverride: ((pid_t) -> CmuxTopProcessArguments?)?
    nonisolated(unsafe) static var surfaceExistsOverride: ((UUID, UUID) -> Bool)?
    nonisolated(unsafe) static var auditLogURLOverride: URL?

    static func reset() {
        approvalOverride = nil
        helperOverride = nil
        isDescendantOverride = nil
        processArgumentsOverride = nil
        surfaceExistsOverride = nil
        auditLogURLOverride = nil
    }
}
#endif
