internal import Foundation

/// Appends exact network-byte-order renderer-control fields.
struct RendererControlWireWriter {
    private(set) var data = Data()

    mutating func append(bytes: [UInt8]) {
        data.append(contentsOf: bytes)
    }

    mutating func append(data value: Data) {
        data.append(value)
    }

    mutating func append(value: UInt8) {
        data.append(value)
    }

    mutating func append(value: UInt16) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    mutating func append(value: UInt32) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    mutating func append(value: UInt64) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    mutating func append(uuid: UUID) {
        var bytes = uuid.uuid
        withUnsafeBytes(of: &bytes) { data.append(contentsOf: $0) }
    }
}
