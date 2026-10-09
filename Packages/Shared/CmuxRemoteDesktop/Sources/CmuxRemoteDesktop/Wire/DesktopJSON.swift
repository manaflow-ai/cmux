import CmuxBrowserStream
import CmuxMobileWire

/// Typed reads from one `desktop/1` or `rd` params JSON object.
struct DesktopJSON {
    let object: [String: JSONValue]

    init(_ value: JSONValue) throws(RdWireError) {
        guard let object = value.objectValue else { throw RdWireError("expected a JSON object") }
        self.object = object
    }

    init(_ object: [String: JSONValue]) {
        self.object = object
    }

    func has(_ key: String) -> Bool {
        if let value = object[key], value != .null { return true }
        return false
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
        case .double(let value)? where value.rounded() == value && abs(value) < 9e15: return Int64(value)
        default: throw RdWireError("\(key): expected integer")
        }
    }

    /// An integer in `range`.
    func int(_ key: String, in range: ClosedRange<Int64>) throws(RdWireError) -> Int {
        let value = try int(key)
        guard range.contains(value) else { throw RdWireError("\(key): out of range") }
        return Int(value)
    }

    func uint32(_ key: String) throws(RdWireError) -> UInt32 {
        UInt32(try int(key, in: 0...Int64(UInt32.max)))
    }

    func array(_ key: String) throws(RdWireError) -> [JSONValue] {
        guard case .array(let value)? = object[key] else { throw RdWireError("\(key): expected array") }
        return value
    }

    func value(_ key: String) throws(RdWireError) -> JSONValue {
        guard let value = object[key] else { throw RdWireError("\(key): missing") }
        return value
    }
}
