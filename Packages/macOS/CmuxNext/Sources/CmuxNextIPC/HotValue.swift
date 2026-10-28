// What every generated hot-message type is, and what its codec refuses (HotLayout.swift).

/// A value with a binary layout: every type HotEmitter generates.
public protocol HotValue: Sendable {
    /// Appends the value's fields in layout order.
    func hotWrite(to writer: inout HotWriter) throws(HotEncodeError)
    /// Reads the value's fields in layout order.
    init(hotReader reader: inout HotReader) throws(HotDecodeError)
}

/// A value its layout cannot carry; the sender writes the message as JSON instead.
public enum HotEncodeError: Error, Hashable, Sendable {
    /// A string longer than its field's `max_bytes`.
    case stringTooLong(length: Int, max: UInt16)
    /// An array longer than its `max_items`.
    case arrayTooLong(length: Int, max: UInt16)
}

/// A payload that is not its layout; the connection treats it as a bad message.
public enum HotDecodeError: Error, Hashable, Sendable {
    /// The payload ends inside a value.
    case truncated
    /// The version byte is another schema revision's.
    case version(name: String, expected: UInt8, found: UInt8)
    /// A tag byte other than 0 (absent or null) and 1 (present).
    case badTag(UInt8)
    /// A boolean byte other than 0 and 1.
    case badBool(UInt8)
    /// An enum index past the type's values.
    case badEnum(type: String, index: UInt8)
    /// A string or array length over its bound.
    case overBound(length: Int, max: UInt16)
    /// A string that is not UTF-8.
    case invalidUTF8
    /// Bytes after the body.
    case trailingBytes(Int)
}
