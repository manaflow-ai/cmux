import CmuxRemoteConnections
import CSSHNative
import Foundation

/// Native libssh connector that opens credential-free SSH handshakes.
public actor MobileRemoteNativeSSHConnector: MobileRemoteSSHConnecting {
    private let configuration: MobileRemoteNativeSSHConfiguration
    public init(configuration: MobileRemoteNativeSSHConfiguration = .defaultConfiguration) { self.configuration = configuration }
    public func handshake(_ request: MobileRemoteSSHConnectionRequest) async throws -> any MobileRemoteSSHHandshake {
        let host = try NativeCString(request.profile.host)
        let user = try NativeCString(request.profile.username)
        let raw = host.withPointer { hostPointer in
            user.withPointer { userPointer in
                cmux_ssh_create(hostPointer, Int32(request.profile.port), userPointer)
            }
        }
        guard let raw else { throw MobileRemoteNativeSSHError.creationFailed }
        let handle = MobileRemoteNativeSSHHandle(raw: raw)
        do {
            try await handle.connect(timeout: configuration.connectTimeout)
            return MobileRemoteNativeSSHHandshake(handle: handle, profile: request.profile)
        } catch { await handle.close(); throw error }
    }
}

/// Native connector timing limits.
public struct MobileRemoteNativeSSHConfiguration: Sendable {
    public let connectTimeout: Duration
    public static let defaultConfiguration = Self(connectTimeout: .seconds(30))
    public init(connectTimeout: Duration) { self.connectTimeout = connectTimeout }
}

private struct NativeCString: Sendable {
    let storage: [UInt8]
    init(_ value: String) throws { guard !value.contains("\0") else { throw MobileRemoteNativeSSHError.invalidCString }; storage = Array(value.utf8)+[0] }
    func withPointer<T>(_ body: (UnsafePointer<CChar>) -> T) -> T {
        storage.withUnsafeBufferPointer { buffer in
            body(UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: CChar.self))
        }
    }
}

private actor MobileRemoteNativeSSHHandle {
    // libssh handles are accessed only through this actor; deinit is the final
    // native teardown path after all actor-isolated operations complete.
    private nonisolated(unsafe) var raw: OpaquePointer?
    private var closed = false
    init(raw: OpaquePointer) { self.raw = raw }
    deinit { if let raw { cmux_ssh_destroy(raw) } }
    func connect(timeout: Duration) async throws {
        let start = ContinuousClock.now
        while !closed {
            guard let raw else { throw MobileRemoteNativeSSHError.closed }
            switch cmux_ssh_connect(raw) {
            case Int32(CMUX_SSH_OK): return
            case Int32(CMUX_SSH_AGAIN):
                if ContinuousClock.now - start >= timeout { throw MobileRemoteNativeSSHError.timeout }
                _ = cmux_ssh_wait(raw, 250)
            default: throw MobileRemoteNativeSSHError.nativeFailure
            }
        }
        throw MobileRemoteNativeSSHError.closed
    }
    func close() { guard !closed else { return }; closed = true; if let raw { cmux_ssh_destroy(raw); self.raw = nil } }
    func hostKey(profileID: UUID) throws -> MobileRemoteSSHHostKeyChallenge {
        guard let raw else { throw MobileRemoteNativeSSHError.closed }
        var algorithm = [CChar](repeating: 0, count: 128), fingerprint = [CChar](repeating: 0, count: 256)
        guard cmux_ssh_host_key(raw, &algorithm, algorithm.count, &fingerprint, fingerprint.count) == Int32(CMUX_SSH_OK) else { throw MobileRemoteNativeSSHError.nativeFailure }
        return try MobileRemoteSSHHostKeyChallenge(profileID: profileID, algorithm: String(decoding: algorithm.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), fingerprint: String(decoding: fingerprint.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }
    func authenticate(_ credential: MobileRemoteCredentialMaterial?, profile: MobileRemoteProfile) throws -> any MobileRemoteSSHSession {
        guard let raw else { throw MobileRemoteNativeSSHError.closed }
        let result: Int32
        switch credential {
        case let .password(value): result = value.withCString { cmux_ssh_auth_password(raw, $0) }
        case .none: result = cmux_ssh_auth_none(raw)
        case let .privateKey(bytes, passphrase):
            let encoded = bytes.base64EncodedString()
            result = encoded.withCString { key in passphrase?.withCString { cmux_ssh_load_private_key(raw, key, $0) } ?? cmux_ssh_load_private_key(raw, key, nil) }
            guard result == Int32(CMUX_SSH_OK), cmux_ssh_auth_key(raw) == Int32(CMUX_SSH_OK) else { throw MobileRemoteNativeSSHError.authenticationFailed }
        }
        guard result == Int32(CMUX_SSH_OK) else { throw MobileRemoteNativeSSHError.authenticationFailed }
        guard cmux_ssh_open_channel(raw) == Int32(CMUX_SSH_OK) else { throw MobileRemoteNativeSSHError.nativeFailure }
        for (name, value) in profile.environment {
            guard cmux_ssh_environment(raw, name, value) == Int32(CMUX_SSH_OK) else { throw MobileRemoteNativeSSHError.nativeFailure }
        }
        switch profile.sessionBackend {
        case .shell:
            guard cmux_ssh_request_pty(raw, 80, 24) == Int32(CMUX_SSH_OK),
                  cmux_ssh_request_shell(raw) == Int32(CMUX_SSH_OK) else { throw MobileRemoteNativeSSHError.nativeFailure }
        case .tmux, .zellij, .herdr, .cmuxTUI:
            throw MobileRemoteNativeSSHError.unsupportedSessionBackend(profile.sessionBackend)
        }
        return MobileRemoteNativeSSHSession(handle: self)
    }

    func read(_ bytes: inout [UInt8], timeoutMilliseconds: Int32) throws -> Int {
        try bytes.withUnsafeMutableBytes { buffer in
            guard let raw else { throw MobileRemoteNativeSSHError.closed }
            let result = cmux_ssh_read_timeout(raw, buffer.baseAddress, UInt32(buffer.count), 0, timeoutMilliseconds)
            if result < 0 { throw MobileRemoteNativeSSHError.nativeFailure }
            return Int(result)
        }
    }

    func write(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            guard let raw else { throw MobileRemoteNativeSSHError.closed }
            let result = data.dropFirst(offset).withUnsafeBytes { buffer -> Int32 in
                cmux_ssh_write(raw, buffer.baseAddress, UInt32(buffer.count))
            }
            if result == 0 { _ = cmux_ssh_wait(raw, 250); continue }
            guard result > 0 else { throw MobileRemoteNativeSSHError.nativeFailure }
            offset += Int(result)
        }
    }

    func resize(columns: Int, rows: Int) throws {
        guard (1...1000).contains(columns), (1...1000).contains(rows),
              cmux_ssh_resize(raw, Int32(columns), Int32(rows)) == Int32(CMUX_SSH_OK) else {
            throw MobileRemoteNativeSSHError.nativeFailure
        }
    }

    func isEOF() -> Bool { guard let raw else { return true }; return cmux_ssh_eof(raw) != 0 }
    func isClosed() -> Bool { guard let raw else { return true }; return closed || cmux_ssh_closed(raw) != 0 }
}

private struct MobileRemoteNativeSSHHandshake: MobileRemoteSSHHandshake {
    let handle: MobileRemoteNativeSSHHandle; let profile: MobileRemoteProfile
    func hostKey() async throws -> MobileRemoteSSHHostKeyChallenge { try await handle.hostKey(profileID: profile.id) }
    func authenticate(credential: MobileRemoteCredentialMaterial?) async throws -> any MobileRemoteSSHSession { try await handle.authenticate(credential, profile: profile) }
    func close() async { await handle.close() }
}
private struct MobileRemoteNativeSSHSession: MobileRemoteSSHSession {
    let handle: MobileRemoteNativeSSHHandle
    func output() -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    while !(await handle.isClosed()) {
                        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
                        let count = try await handle.read(&bytes, timeoutMilliseconds: 250)
                        if count > 0 { continuation.yield(Data(bytes.prefix(count))) }
                        if count == 0 {
                            let eof = await handle.isEOF()
                            if eof { break }
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
    }
    func sendInput(_ data: Data) async throws { try await handle.write(data) }
    func resize(columns: Int, rows: Int) async throws { try await handle.resize(columns: columns, rows: rows) }
    func close() async { await handle.close() }
}
/// Native adapter errors without secret material.
public enum MobileRemoteNativeSSHError: Error, Equatable, Sendable {
    case creationFailed
    case invalidCString
    case timeout
    case nativeFailure
    case authenticationFailed
    case closed
    case unsupportedSessionBackend(MobileRemoteSessionBackend)
}
