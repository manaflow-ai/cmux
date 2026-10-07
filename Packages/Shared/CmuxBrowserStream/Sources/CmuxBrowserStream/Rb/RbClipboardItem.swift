import CmuxMobileWire

/// One pasteboard item: UTF-8 text for text types, base64 for binary types.
public struct RbClipboardItem: Hashable, Sendable {
    public var mime: String
    public var base64: Bool
    public var data: String

    public init(mime: String, base64: Bool, data: String) {
        self.mime = mime
        self.base64 = base64
        self.data = data
    }

    public static func text(_ text: String) -> RbClipboardItem {
        RbClipboardItem(mime: "text/plain", base64: false, data: text)
    }

    /// The text of a `text/plain` item.
    public var plainText: String? {
        mime.hasPrefix("text/plain") && !base64 ? data : nil
    }

    var jsonValue: JSONValue { .object(["mime": .string(mime), "base64": .bool(base64), "data": .string(data)]) }

    init(json: JSONValue) throws(RdWireError) {
        let r = try RbJSONReader(json)
        mime = try r.string("mime")
        base64 = try r.bool("base64")
        data = try r.string("data")
    }
}
