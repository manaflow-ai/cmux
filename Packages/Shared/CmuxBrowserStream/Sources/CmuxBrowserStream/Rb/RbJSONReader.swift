import CmuxMobileWire
import Foundation

/// Typed reads from one `cmux.rb/1` JSON object.
struct RbJSONReader {
    let object: [String: JSONValue]

    init(_ value: JSONValue) throws(RdWireError) {
        guard let object = value.objectValue else { throw RdWireError("rb message is not an object") }
        self.object = object
    }

    func string(_ key: String) throws(RdWireError) -> String {
        guard let value = object[key]?.stringValue else { throw RdWireError("\(key): expected string") }
        return value
    }

    func optionalString(_ key: String) -> String? {
        object[key]?.stringValue
    }

    func bool(_ key: String) throws(RdWireError) -> Bool {
        guard case .bool(let value)? = object[key] else { throw RdWireError("\(key): expected bool") }
        return value
    }

    func double(_ key: String) throws(RdWireError) -> Double {
        switch object[key] {
        case .int(let value)?: return Double(value)
        case .double(let value)?: return value
        default: throw RdWireError("\(key): expected number")
        }
    }

    func int(_ key: String) throws(RdWireError) -> Int64 {
        switch object[key] {
        case .int(let value)?: return value
        case .double(let value)? where value.rounded() == value: return Int64(value)
        default: throw RdWireError("\(key): expected integer")
        }
    }

    func uint32(_ key: String) throws(RdWireError) -> UInt32 {
        let value = try int(key)
        guard let out = UInt32(exactly: value) else { throw RdWireError("\(key): out of range") }
        return out
    }

    func uint64(_ key: String) throws(RdWireError) -> UInt64 {
        let value = try int(key)
        guard let out = UInt64(exactly: value) else { throw RdWireError("\(key): out of range") }
        return out
    }

    /// Reads an optional unsigned integer while preserving the distinction
    /// between a missing field and a malformed value. This is useful for
    /// vectors that contain an older shape of a message whose newer form
    /// carries a request identifier.
    func optionalUInt64(_ key: String) throws(RdWireError) -> UInt64? {
        guard object[key] != nil else { return nil }
        return try uint64(key)
    }

    func array(_ key: String) throws(RdWireError) -> [JSONValue] {
        guard case .array(let value)? = object[key] else { throw RdWireError("\(key): expected array") }
        return value
    }

    func value(_ key: String) throws(RdWireError) -> JSONValue {
        guard let value = object[key] else { throw RdWireError("\(key): missing") }
        return value
    }

    func isNull(_ key: String) -> Bool {
        object[key] == nil || object[key] == .null
    }
}

extension Optional where Wrapped == String {
    var rbJSON: JSONValue { map { .string($0) } ?? .null }
}
