import Darwin
public import Foundation
@preconcurrency import CmuxIrohC

final class CmxIrohEndpointReference: @unchecked Sendable {
    let raw: OpaquePointer

    init(raw: OpaquePointer) {
        self.raw = raw
    }
}

final class CmxIrohConnectionReference: @unchecked Sendable {
    let raw: OpaquePointer

    init(raw: OpaquePointer) {
        self.raw = raw
    }
}

protocol CmxIrohFFIClient: Sendable {
    func generateSecretKey() throws -> Data
    func bindEndpoint(
        secretKey: Data,
        enableRelay: Bool,
        acceptConnections: Bool
    ) throws -> CmxIrohEndpointReference
    func endpointID(_ endpoint: CmxIrohEndpointReference) -> String?
    func routeJSON(_ endpoint: CmxIrohEndpointReference) -> String?
    func online(endpoint: CmxIrohEndpointReference, timeoutMilliseconds: UInt64) throws
    func accept(
        endpoint: CmxIrohEndpointReference,
        timeoutMilliseconds: UInt64
    ) throws -> CmxIrohConnectionReference
    func connect(
        endpoint: CmxIrohEndpointReference,
        peerID: String,
        relayURL: String?,
        directAddrs: [String],
        timeoutMilliseconds: UInt64
    ) throws -> CmxIrohConnectionReference
    func receive(connection: CmxIrohConnectionReference, maximumLength: Int) throws -> Data?
    func send(connection: CmxIrohConnectionReference, data: Data) throws
    func close(connection: CmxIrohConnectionReference)
    func close(endpoint: CmxIrohEndpointReference)
}

struct CmxIrohSystemFFIClient: CmxIrohFFIClient {
    private static let errorMessageCapacity = 2_048

    func generateSecretKey() throws -> Data {
        var key = [UInt8](repeating: 0, count: Int(CMUX_IROH_SECRET_KEY_LEN))
        try key.withUnsafeMutableBufferPointer { keyBuffer in
            try withIrohError { error in
                let rc = cmux_iroh_secret_key_generate(
                    keyBuffer.baseAddress,
                    keyBuffer.count,
                    error
                )
                guard rc == 0 else {
                    throw failure(from: error)
                }
            }
        }
        return Data(key)
    }

    func bindEndpoint(
        secretKey: Data,
        enableRelay: Bool,
        acceptConnections: Bool
    ) throws -> CmxIrohEndpointReference {
        try secretKey.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw CmxIrohFailure(
                    kind: .invalidArgument,
                    message: "empty iroh secret key"
                )
            }
            return try withIrohError { error in
                guard let endpoint = cmux_iroh_endpoint_bind(
                    baseAddress,
                    secretKey.count,
                    enableRelay,
                    acceptConnections,
                    error
                ) else {
                    throw failure(from: error)
                }
                return CmxIrohEndpointReference(raw: endpoint)
            }
        }
    }

    func endpointID(_ endpoint: CmxIrohEndpointReference) -> String? {
        guard let cString = cmux_iroh_endpoint_id(endpoint.raw) else {
            return nil
        }
        defer { cmux_iroh_string_free(cString) }
        return String(cString: cString)
    }

    func routeJSON(_ endpoint: CmxIrohEndpointReference) -> String? {
        guard let cString = cmux_iroh_endpoint_route_json(endpoint.raw) else {
            return nil
        }
        defer { cmux_iroh_string_free(cString) }
        return String(cString: cString)
    }

    func online(endpoint: CmxIrohEndpointReference, timeoutMilliseconds: UInt64) throws {
        try withIrohError { error in
            let rc = cmux_iroh_endpoint_online(endpoint.raw, timeoutMilliseconds, error)
            guard rc == 0 else {
                throw failure(from: error)
            }
        }
    }

    func accept(
        endpoint: CmxIrohEndpointReference,
        timeoutMilliseconds: UInt64
    ) throws -> CmxIrohConnectionReference {
        try withIrohError { error in
            guard let connection = cmux_iroh_endpoint_accept(
                endpoint.raw,
                timeoutMilliseconds,
                error
            ) else {
                throw failure(from: error)
            }
            return CmxIrohConnectionReference(raw: connection)
        }
    }

    func connect(
        endpoint: CmxIrohEndpointReference,
        peerID: String,
        relayURL: String?,
        directAddrs: [String],
        timeoutMilliseconds: UInt64
    ) throws -> CmxIrohConnectionReference {
        let duplicatedAddrs = try directAddrs.map { address in
            guard let copy = strdup(address) else {
                throw CmxIrohFailure(kind: .internalFailure, message: "failed to allocate direct address")
            }
            return copy
        }
        defer {
            duplicatedAddrs.forEach { free($0) }
        }
        var addrPointers = duplicatedAddrs.map { Optional(UnsafePointer<CChar>($0)) }

        return try peerID.withCString { peerPtr in
            try withOptionalCString(relayURL) { relayPtr in
                try addrPointers.withUnsafeBufferPointer { addrBuffer in
                    try withIrohError { error in
                        guard let connection = cmux_iroh_endpoint_connect(
                            endpoint.raw,
                            peerPtr,
                            relayPtr,
                            addrBuffer.baseAddress,
                            addrBuffer.count,
                            timeoutMilliseconds,
                            error
                        ) else {
                            throw failure(from: error)
                        }
                        return CmxIrohConnectionReference(raw: connection)
                    }
                }
            }
        }
    }

    func receive(connection: CmxIrohConnectionReference, maximumLength: Int) throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: maximumLength)
        return try buffer.withUnsafeMutableBufferPointer { bytes in
            try withIrohError { error in
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
                    throw failure(from: error)
                }
                return Data(bytes.prefix(Int(count)))
            }
        }
    }

    func send(connection: CmxIrohConnectionReference, data: Data) throws {
        guard !data.isEmpty else {
            return
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            try withIrohError { error in
                let rc = cmux_iroh_connection_send(
                    connection.raw,
                    baseAddress,
                    data.count,
                    error
                )
                guard rc == 0 else {
                    throw failure(from: error)
                }
            }
        }
    }

    func close(connection: CmxIrohConnectionReference) {
        cmux_iroh_connection_close(connection.raw)
    }

    func close(endpoint: CmxIrohEndpointReference) {
        cmux_iroh_endpoint_close(endpoint.raw)
    }

    private func withOptionalCString<T>(
        _ string: String?,
        _ body: (UnsafePointer<CChar>?) throws -> T
    ) throws -> T {
        guard let string else {
            return try body(nil)
        }
        return try string.withCString { pointer in
            try body(pointer)
        }
    }

    private func withIrohError<T>(_ body: (UnsafeMutablePointer<CmuxIrohError>) throws -> T) throws -> T {
        var message = [CChar](repeating: 0, count: Self.errorMessageCapacity)
        return try message.withUnsafeMutableBufferPointer { buffer in
            var error = CmuxIrohError(
                kind: CmxIrohErrorKind.none.rawValue,
                message: buffer.baseAddress,
                message_cap: buffer.count
            )
            return try body(&error)
        }
    }

    private func failure(from error: UnsafeMutablePointer<CmuxIrohError>) -> CmxIrohFailure {
        let message: String
        if let cString = error.pointee.message, cString.pointee != 0 {
            message = String(cString: cString)
        } else {
            message = "iroh operation failed"
        }
        return CmxIrohFailure(
            kind: CmxIrohErrorKind(rawFFIValue: error.pointee.kind),
            message: message
        )
    }
}
