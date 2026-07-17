public import Foundation
public import XPC

/// Allocation-light construction and parsing of renderer XPC dictionaries.
///
/// Hot input messages use typed XPC fields directly. They do not pass through
/// JSON, property lists, `Codable`, or intermediate Foundation dictionaries.
public enum RendererIPCMessage {
    /// Creates a message with its operation and protocol version populated.
    public static func make(_ operation: RendererIPCOperation) -> xpc_object_t {
        let message = xpc_dictionary_create_empty()
        xpc_dictionary_set_uint64(message, RendererIPCKey.operation, operation.rawValue)
        xpc_dictionary_set_uint64(
            message,
            RendererIPCKey.protocolVersion,
            RendererIPCProtocol.version
        )
        return message
    }

    /// Returns the operation when the message is a supported dictionary.
    public static func operation(in message: xpc_object_t) -> RendererIPCOperation? {
        guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else { return nil }
        let version = xpc_dictionary_get_uint64(message, RendererIPCKey.protocolVersion)
        guard version == RendererIPCProtocol.version else { return nil }
        return RendererIPCOperation(rawValue: xpc_dictionary_get_uint64(
            message,
            RendererIPCKey.operation
        ))
    }

    /// Stores a UUID as its 16-byte representation.
    public static func setUUID(_ value: UUID, forKey key: String, in message: xpc_object_t) {
        var bytes = value.uuid
        withUnsafeBytes(of: &bytes) { buffer in
            xpc_dictionary_set_data(message, key, buffer.baseAddress, buffer.count)
        }
    }

    /// Reads a UUID stored by ``setUUID(_:forKey:in:)``.
    public static func uuid(forKey key: String, in message: xpc_object_t) -> UUID? {
        var count = 0
        guard let pointer = xpc_dictionary_get_data(message, key, &count),
              count == MemoryLayout<uuid_t>.size else {
            return nil
        }
        let bytes = pointer.loadUnaligned(as: uuid_t.self)
        return UUID(uuid: bytes)
    }

    /// Stores bytes without a Foundation container on the wire.
    public static func setData(_ value: Data, forKey key: String, in message: xpc_object_t) {
        value.withUnsafeBytes { buffer in
            xpc_dictionary_set_data(message, key, buffer.baseAddress, buffer.count)
        }
    }

    /// Reads immutable message bytes into owned `Data`.
    public static func data(forKey key: String, in message: xpc_object_t) -> Data? {
        var count = 0
        guard let pointer = xpc_dictionary_get_data(message, key, &count) else { return nil }
        return Data(bytes: pointer, count: count)
    }
}
