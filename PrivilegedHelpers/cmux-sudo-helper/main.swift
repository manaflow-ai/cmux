import CryptoKit
import Darwin
import Foundation
import Security

private let socketPath = "/var/run/cmux-sudo-helper.sock"
private let secureSearchPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
private let maxCapturedOutputBytes = 2 * 1024 * 1024
private let allowedBundleIdentifiers: Set<String> = [
    "com.cmuxterm.app",
    "com.cmuxterm.app.debug",
    "com.cmuxterm.app.nightly",
]

struct HelperError: LocalizedError {
    let code: String
    let message: String

    var errorDescription: String? { message }
}

struct PeerIdentity {
    let pid: pid_t
    let uid: uid_t
}

struct HelperEnvelope {
    let payload: [String: Any]
    let signature: String
    let publicKey: String
}

@main
enum CMUXSudoHelper {
    static func main() {
        do {
            try runOnce()
        } catch {
            writeLog("fatal \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func runOnce() throws {
        let listener = try makeListener()
        defer {
            Darwin.close(listener)
            unlink(socketPath)
        }

        let client = accept(listener, nil, nil)
        guard client >= 0 else {
            throw HelperError(code: "accept_failed", message: errnoMessage("accept"))
        }
        defer { Darwin.close(client) }

        let response: [String: Any]
        do {
            let peer = try peerIdentity(for: client)
            try validatePeerApp(pid: peer.pid)
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
            response = [
                "status": "helper_error",
                "exit_code": NSNull(),
                "stdout": "",
                "stderr": "",
                "error_code": "unexpected_error",
                "message": error.localizedDescription,
            ]
        }
        try writeJSONLine(response, to: client)
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

        _ = chown(socketPath, 0, 80)
        _ = chmod(socketPath, 0o660)

        guard listen(fd, 8) == 0 else {
            let message = errnoMessage("listen")
            Darwin.close(fd)
            throw HelperError(code: "listen_failed", message: message)
        }
        return fd
    }

    private static func peerIdentity(for fd: Int32) throws -> PeerIdentity {
        var pid: pid_t = 0
        var pidSize = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidSize) == 0, pid > 0 else {
            throw HelperError(code: "peer_pid_unavailable", message: errnoMessage("LOCAL_PEERPID"))
        }

        var cred = xucred()
        var credSize = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &credSize) == 0 else {
            throw HelperError(code: "peer_uid_unavailable", message: errnoMessage("LOCAL_PEERCRED"))
        }
        return PeerIdentity(pid: pid, uid: cred.cr_uid)
    }

    private static func validatePeerApp(pid: pid_t) throws {
        let attributes = [kSecGuestAttributePid as String: pid] as CFDictionary
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
              let identifier = info[kSecCodeInfoIdentifier as String] as? String,
              allowedBundleIdentifiers.contains(identifier) else {
            throw HelperError(code: "peer_code_rejected", message: "Requesting process is not a cmux app")
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
    }

    private static func execute(envelope: HelperEnvelope, peer: PeerIdentity) throws -> [String: Any] {
        guard let argv = envelope.payload["argv"] as? [String], !argv.isEmpty else {
            throw HelperError(code: "missing_argv", message: "Helper request has no command")
        }
        guard let requesterUID = intValue(envelope.payload["requester_uid"]),
              requesterUID == Int(peer.uid) else {
            throw HelperError(code: "uid_mismatch", message: "Requester uid does not match the cmux app uid")
        }

        let executable = try resolveExecutable(argv[0])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        process.environment = ["PATH": secureSearchPath.joined(separator: ":")]
        if let cwd = envelope.payload["cwd"] as? String,
           !cwd.isEmpty,
           FileManager.default.fileExists(atPath: cwd) {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdout = OutputCollector()
        let stderr = OutputCollector()
        stdoutPipe.fileHandleForReading.readabilityHandler = { stdout.append($0.availableData) }
        stderrPipe.fileHandleForReading.readabilityHandler = { stderr.append($0.availableData) }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        try process.run()
        semaphore.wait()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdout.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        stderr.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

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
            return command
        }

        for directory in secureSearchPath {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(command).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        throw HelperError(code: "command_not_found", message: "Command was not found in the helper search path")
    }

    private static func readLineData(from fd: Int32) throws -> Data {
        var data = Data()
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(fd, &byte, 1)
            if count < 0 {
                if errno == EINTR { continue }
                throw HelperError(code: "read_failed", message: errnoMessage("read"))
            }
            if count == 0 || byte == 0x0a {
                return data
            }
            data.append(byte)
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

    private static func canonicalJSONData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
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
        FileHandle.standardError.write(Data("[cmux-sudo-helper] \(message)\n".utf8))
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
