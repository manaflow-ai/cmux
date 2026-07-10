import Darwin
import Foundation
import CmuxIrohFFI

final class MobileHostIrohEndpointReference: @unchecked Sendable {
    let raw: OpaquePointer

    init(raw: OpaquePointer) {
        self.raw = raw
    }
}

final class MobileHostIrohConnectionReference: @unchecked Sendable {
    let raw: OpaquePointer

    init(raw: OpaquePointer) {
        self.raw = raw
    }
}

struct MobileHostIrohFailure: Error, Equatable, Sendable {
    let kind: MobileHostIrohErrorKind
    let message: String
}

enum MobileHostIrohErrorKind: UInt32, Sendable, Equatable {
    case none = 0
    case invalidArgument = 1
    case timedOut = 2
    case connectionRefused = 3
    case hostUnreachable = 4
    case permissionDenied = 5
    case dnsFailed = 6
    case secureChannelFailed = 7
    case endpointClosed = 8
    case notConnected = 9
    case io = 10
    case internalFailure = 11
    case unknown = 0xffff_ffff

    init(rawFFIValue: UInt32) {
        self = Self(rawValue: rawFFIValue) ?? .unknown
    }
}

protocol MobileHostIrohFFIClient: Sendable {
    func generateSecretKey() throws -> Data
    func bindEndpoint(
        secretKey: Data,
        enableRelay: Bool,
        acceptConnections: Bool
    ) throws -> MobileHostIrohEndpointReference
    func endpointID(_ endpoint: MobileHostIrohEndpointReference) -> String?
    func routeJSON(_ endpoint: MobileHostIrohEndpointReference) -> String?
    func accept(
        endpoint: MobileHostIrohEndpointReference,
        timeoutMilliseconds: UInt64
    ) throws -> MobileHostIrohConnectionReference
    func receive(connection: MobileHostIrohConnectionReference, maximumLength: Int) throws -> Data?
    func send(connection: MobileHostIrohConnectionReference, data: Data) throws
    func close(connection: MobileHostIrohConnectionReference)
    func close(endpoint: MobileHostIrohEndpointReference)
}

struct MobileHostIrohSystemFFIClient: MobileHostIrohFFIClient {
    private static let errorMessageCapacity = 2_048

    func generateSecretKey() throws -> Data {
        var key = [UInt8](repeating: 0, count: Int(CMUX_IROH_SECRET_KEY_LEN))
        try key.withUnsafeMutableBufferPointer { keyBuffer in
            try withIrohError { rawError in
                let error = rawError.assumingMemoryBound(to: CmuxIrohError.self)
                let rc = cmux_iroh_secret_key_generate(
                    keyBuffer.baseAddress,
                    keyBuffer.count,
                    error
                )
                guard rc == 0 else {
                    throw failure(from: rawError)
                }
            }
        }
        return Data(key)
    }

    func bindEndpoint(
        secretKey: Data,
        enableRelay: Bool,
        acceptConnections: Bool
    ) throws -> MobileHostIrohEndpointReference {
        try secretKey.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw MobileHostIrohFailure(kind: .invalidArgument, message: "empty iroh secret key")
            }
            return try withIrohError { rawError in
                let error = rawError.assumingMemoryBound(to: CmuxIrohError.self)
                guard let endpoint = cmux_iroh_endpoint_bind(
                    baseAddress,
                    secretKey.count,
                    enableRelay,
                    acceptConnections,
                    error
                ) else {
                    throw failure(from: rawError)
                }
                return MobileHostIrohEndpointReference(raw: endpoint)
            }
        }
    }

    func endpointID(_ endpoint: MobileHostIrohEndpointReference) -> String? {
        guard let cString = cmux_iroh_endpoint_id(endpoint.raw) else {
            return nil
        }
        defer { cmux_iroh_string_free(cString) }
        return String(cString: cString)
    }

    func routeJSON(_ endpoint: MobileHostIrohEndpointReference) -> String? {
        guard let cString = cmux_iroh_endpoint_route_json(endpoint.raw) else {
            return nil
        }
        defer { cmux_iroh_string_free(cString) }
        return String(cString: cString)
    }

    func accept(
        endpoint: MobileHostIrohEndpointReference,
        timeoutMilliseconds: UInt64
    ) throws -> MobileHostIrohConnectionReference {
        try withIrohError { rawError in
            let error = rawError.assumingMemoryBound(to: CmuxIrohError.self)
            guard let connection = cmux_iroh_endpoint_accept(
                endpoint.raw,
                timeoutMilliseconds,
                error
            ) else {
                throw failure(from: rawError)
            }
            return MobileHostIrohConnectionReference(raw: connection)
        }
    }

    func receive(connection: MobileHostIrohConnectionReference, maximumLength: Int) throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: maximumLength)
        return try buffer.withUnsafeMutableBufferPointer { bytes in
            try withIrohError { rawError in
                let error = rawError.assumingMemoryBound(to: CmuxIrohError.self)
                let count = cmux_iroh_connection_recv(
                    connection.raw,
                    bytes.baseAddress,
                    bytes.count,
                    error
                )
                if count == 0 {
                    return nil
                }
                guard count > 0 else {
                    throw failure(from: rawError)
                }
                return Data(bytes.prefix(Int(count)))
            }
        }
    }

    func send(connection: MobileHostIrohConnectionReference, data: Data) throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            try withIrohError { rawError in
                let error = rawError.assumingMemoryBound(to: CmuxIrohError.self)
                let rc = cmux_iroh_connection_send(
                    connection.raw,
                    baseAddress,
                    data.count,
                    error
                )
                guard rc == 0 else {
                    throw failure(from: rawError)
                }
            }
        }
    }

    func close(connection: MobileHostIrohConnectionReference) {
        cmux_iroh_connection_close(connection.raw)
    }

    func close(endpoint: MobileHostIrohEndpointReference) {
        cmux_iroh_endpoint_close(endpoint.raw)
    }

    private func withIrohError<T>(_ body: (UnsafeMutableRawPointer) throws -> T) throws -> T {
        var message = [CChar](repeating: 0, count: Self.errorMessageCapacity)
        return try message.withUnsafeMutableBufferPointer { buffer in
            var error = CmuxIrohError(
                kind: MobileHostIrohErrorKind.none.rawValue,
                message: buffer.baseAddress,
                message_cap: buffer.count
            )
            return try withUnsafeMutablePointer(to: &error) { errorPointer in
                try body(UnsafeMutableRawPointer(errorPointer))
            }
        }
    }

    private func failure(from rawError: UnsafeMutableRawPointer) -> MobileHostIrohFailure {
        let error = rawError.assumingMemoryBound(to: CmuxIrohError.self)
        let message: String
        if let cString = error.pointee.message, cString.pointee != 0 {
            message = String(cString: cString)
        } else {
            message = "iroh operation failed"
        }
        return MobileHostIrohFailure(
            kind: MobileHostIrohErrorKind(rawFFIValue: error.pointee.kind),
            message: message
        )
    }
}
